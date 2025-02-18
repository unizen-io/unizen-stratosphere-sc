use anchor_lang::{
    prelude::*,
    solana_program::{entrypoint::ProgramResult, instruction::Instruction, program::invoke_signed},
    system_program,
};
use anchor_spl::token::{self, Mint, Token, TokenAccount};

use crate::constants;
use crate::errors;

mod jupiter {
    use anchor_lang::declare_id;
    declare_id!("JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4");
}

#[derive(Clone)]
pub struct Jupiter;

impl anchor_lang::Id for Jupiter {
    fn id() -> Pubkey {
        jupiter::id()
    }
}

pub fn swap_on_jupiter(
    remaining_accounts: &[AccountInfo],
    jupiter_program: Program<Jupiter>,
    data: Vec<u8>,
) -> ProgramResult {
    msg!("Swap on Jupiter");

    let accounts: Vec<AccountMeta> = remaining_accounts
        .iter()
        .map(|acc| AccountMeta {
            pubkey: *acc.key,
            is_signer: acc.is_signer,
            is_writable: acc.is_writable,
        })
        .collect();

    invoke_signed(
        &Instruction {
            program_id: *jupiter_program.key,
            accounts,
            data,
        },
        remaining_accounts,
        &[],
    )
}

pub fn wrap_user_sol<'info>(
    system_program: Program<'info, System>,
    token_program: Program<'info, Token>,
    user: Signer<'info>,
    wsol_receive_account: Account<'info, TokenAccount>,
    amount: u64,
) -> Result<()> {
    msg!("Wrap user's SOL");
    system_program::transfer(
        CpiContext::new(
            system_program.to_account_info(),
            system_program::Transfer {
                from: user.to_account_info(),
                to: wsol_receive_account.to_account_info(),
            },
        ),
        amount,
    )?;

    token::sync_native(CpiContext::new(
        token_program.to_account_info(),
        token::SyncNative {
            account: wsol_receive_account.to_account_info(),
        },
    ))?;

    Ok(())
}

pub fn take_integrator_fee<'info>(
    accounts: AccountsForFee,
    in_amount: u64,
    fee_percent: u64,
    share_percent: u64,
) -> Result<()> {
    emit!(TakeFee {
        user: accounts.user_token_account.owner.to_string(),
        token: accounts.user_token_account.mint.to_string(),
        amount: in_amount,
        fee_percent,
        share_percent
    });

    if fee_percent == 0 {
        return Ok(());
    }

    let total_fee = in_amount * fee_percent / constants::FEE_DENOM;
    let mut unizen_fee: u64 = 0;

    if share_percent > 0 {
        unizen_fee = total_fee * share_percent / constants::FEE_DENOM;
        msg!("Transfer fee to Unizen");
        token::transfer(
            CpiContext::new(
                accounts.token_program.to_account_info(),
                token::Transfer {
                    from: accounts.user_token_account.to_account_info(),
                    to: accounts.unizen_token_account.to_account_info(),
                    authority: accounts.user.to_account_info(),
                },
            ),
            unizen_fee,
        )?;
    }

    msg!("Transfer fee to integrator");
    token::transfer(
        CpiContext::new(
            accounts.token_program.to_account_info(),
            token::Transfer {
                from: accounts.user_token_account.to_account_info(),
                to: accounts.integrator_token_account.to_account_info(),
                authority: accounts.user.to_account_info(),
            },
        ),
        total_fee - unizen_fee,
    )?;

    Ok(())
}

pub fn assert_amount_out(prev_bal: u64, post_bal: u64, threshold: u64) -> Result<()> {
    if post_bal
        .checked_sub(prev_bal)
        .ok_or_else(|| error!(errors::ErrorCode::Underflow))?
        < threshold
    {
        msg!(
            "Error: Out amount after swap is {} which is lower than expected {}.",
            post_bal - prev_bal,
            threshold
        );
        return err!(errors::ErrorCode::InvalidSwapAmount);
    }

    Ok(())
}

pub fn create_program_wsol_idempotent<'info>(
    program_authority: SystemAccount<'info>,
    program_wsol: UncheckedAccount<'info>,
    sol_mint: Account<'info, Mint>,
    token_program: Program<'info, Token>,
    system_program: Program<'info, System>,
    authority_bump: &[u8],
    wsol_bump: &[u8],
) -> Result<TokenAccount> {
    if program_wsol.data_is_empty() {
        let signer_seeds: &[&[&[u8]]] = &[
            &[constants::AUTHORITY_SEED, authority_bump],
            &[constants::WSOL_SEED, wsol_bump],
        ];

        msg!("Initialize program wSOL account");
        let rent = Rent::get()?;
        let space = TokenAccount::LEN;
        let lamports = rent.minimum_balance(space);
        system_program::create_account(
            CpiContext::new_with_signer(
                system_program.to_account_info(),
                system_program::CreateAccount {
                    from: program_authority.to_account_info(),
                    to: program_wsol.to_account_info(),
                },
                signer_seeds,
            ),
            lamports,
            space as u64,
            token_program.key,
        )?;

        msg!("Initialize program wSOL token account");
        token::initialize_account3(CpiContext::new(
            token_program.to_account_info(),
            token::InitializeAccount3 {
                account: program_wsol.to_account_info(),
                mint: sol_mint.to_account_info(),
                authority: program_authority.to_account_info(),
            },
        ))?;

        let data = program_wsol.try_borrow_data()?;
        let wsol_token_account = TokenAccount::try_deserialize(&mut data.as_ref())?;

        Ok(wsol_token_account)
    } else {
        let data = program_wsol.try_borrow_data()?;
        let wsol_token_account = TokenAccount::try_deserialize(&mut data.as_ref())?;
        if &wsol_token_account.owner != program_authority.key {
            return err!(errors::ErrorCode::IncorrectOwner);
        }

        Ok(wsol_token_account)
    }
}

pub fn close_program_wsol<'info>(
    program_authority: SystemAccount<'info>,
    program_wsol: UncheckedAccount<'info>,
    receiver: SystemAccount<'info>,
    token_program: Program<'info, Token>,
    system_program: Program<'info, System>,
    authority_bump: &[u8],
) -> Result<()> {
    let signer_seeds: &[&[&[u8]]] = &[&[constants::AUTHORITY_SEED, authority_bump]];

    let wsol_balance = program_wsol.lamports();
    let rent = Rent::get()?;
    let rent_lamports = rent.minimum_balance(TokenAccount::LEN);
    let out_amount = wsol_balance - rent_lamports;

    msg!("Close program wSOL token account");
    token::close_account(CpiContext::new_with_signer(
        token_program.to_account_info(),
        token::CloseAccount {
            account: program_wsol.to_account_info(),
            destination: program_authority.to_account_info(),
            authority: program_authority.to_account_info(),
        },
        signer_seeds,
    ))?;

    msg!("Transfer SOL to receiver");
    system_program::transfer(
        CpiContext::new_with_signer(
            system_program.to_account_info(),
            system_program::Transfer {
                from: program_authority.to_account_info(),
                to: receiver.to_account_info(),
            },
            signer_seeds,
        ),
        out_amount,
    )
}

#[derive(Accounts)]
pub struct AccountsForFee<'info> {
    pub user: Signer<'info>,
    pub token_program: Program<'info, Token>,
    pub user_token_account: Account<'info, TokenAccount>,
    pub unizen_token_account: Account<'info, TokenAccount>,
    pub integrator_token_account: Account<'info, TokenAccount>,
}

#[event]
pub struct TakeFee {
    pub user: String,
    pub token: String,
    pub amount: u64,
    pub fee_percent: u64,
    pub share_percent: u64,
}
