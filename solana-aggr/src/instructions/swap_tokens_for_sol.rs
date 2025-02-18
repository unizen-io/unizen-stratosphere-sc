use anchor_lang::prelude::*;
use anchor_spl::token::{ Mint, Token, TokenAccount};

use crate::{constants::*, helpers::* };

pub fn swap_tokens_for_sol(
    ctx: Context<SwapTokensForSol>,
    amount_in: u64,
    amount_out_min: u64,
    fee_percent: u64,
    share_percent: u64,
    data: Vec<u8>,
) -> Result<()> {
    take_integrator_fee(
        AccountsForFee {
            user: ctx.accounts.user.clone(),
            token_program: ctx.accounts.token_program.clone(),
            user_token_account: ctx.accounts.user_src_ata.clone(),
            unizen_token_account: ctx.accounts.unizen_src_ata.clone(),
            integrator_token_account: ctx.accounts.integrator_src_ata.clone(),
        },
        amount_in,
        fee_percent,
        share_percent,
    )?;

    let authority_bump = ctx.bumps.program_authority.to_le_bytes();
    let wsol_bump = ctx.bumps.program_wsol.to_le_bytes();
    create_program_wsol_idempotent(
        ctx.accounts.program_authority.clone(),
        ctx.accounts.program_wsol.clone(),
        ctx.accounts.sol_mint.clone(),
        ctx.accounts.token_program.clone(),
        ctx.accounts.system_program.clone(),
        &authority_bump,
        &wsol_bump,
    )?;

    let prev_sol_bal = ctx.accounts.receiver.to_account_info().get_lamports();

    swap_on_jupiter(
        ctx.remaining_accounts,
        ctx.accounts.jupiter_program.clone(),
        data,
    )?;

    close_program_wsol(
        ctx.accounts.program_authority.clone(),
        ctx.accounts.program_wsol.clone(),
        ctx.accounts.receiver.clone(),
        ctx.accounts.token_program.clone(),
        ctx.accounts.system_program.clone(),
        &authority_bump,
    )?;

    let post_sol_bal = ctx.accounts.receiver.to_account_info().get_lamports();
    assert_amount_out(prev_sol_bal, post_sol_bal, amount_out_min)
}



#[derive(Accounts)]
pub struct SwapTokensForSol<'info> {
    #[account(mut, seeds = [AUTHORITY_SEED], bump)]
    pub program_authority: SystemAccount<'info>,
    /// CHECK: This may not be initialized yet.
    #[account(mut, seeds = [WSOL_SEED], bump)]
    pub program_wsol: UncheckedAccount<'info>,
    pub user: Signer<'info>,
    #[account(mut)]
    pub receiver: SystemAccount<'info>,
    pub src_token: Account<'info, Mint>,
    #[account(address = NATIVE_MINT)]
    pub sol_mint: Account<'info, Mint>,
    #[account(
        mut,        
        associated_token::mint = src_token,
        associated_token::authority = user
    )]
    pub user_src_ata: Account<'info, TokenAccount>,
    #[account(
        mut,        
        associated_token::mint = src_token,
        associated_token::authority = UNIZEN
    )]
    pub unizen_src_ata: Account<'info, TokenAccount>,
    #[account(mut)]
    pub integrator_src_ata: Account<'info, TokenAccount>,
    pub jupiter_program: Program<'info, Jupiter>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}

