use anchor_lang::prelude::*;
use anchor_spl::token::{ Mint, Token, TokenAccount};

use crate::{constants::*, helpers::* };

pub fn swap_sol_for_tokens(
    ctx: Context<SwapSolForTokens>,
    amount_in: u64,
    amount_out_min: u64,
    fee_percent: u64,
    share_percent: u64,
    data: Vec<u8>,
) -> Result<()> {
    wrap_user_sol(
        ctx.accounts.system_program.clone(),
        ctx.accounts.token_program.clone(),
        ctx.accounts.user.clone(),
        ctx.accounts.user_wsol_ata.clone(),
        amount_in,
    )?;

    take_integrator_fee(
        AccountsForFee {
            user: ctx.accounts.user.clone(),
            token_program: ctx.accounts.token_program.clone(),
            user_token_account: ctx.accounts.user_wsol_ata.clone(),
            unizen_token_account: ctx.accounts.unizen_wsol_ata.clone(),
            integrator_token_account: ctx.accounts.integrator_wsol_ata.clone(),
        },
        amount_in,
        fee_percent,
        share_percent,
    )?;

    let prev_bal = ctx.accounts.receiver_dst_ata.amount;

    swap_on_jupiter(
        ctx.remaining_accounts,
        ctx.accounts.jupiter_program.clone(),
        data,
    )?;

    ctx.accounts.receiver_dst_ata.reload()?;
    let post_bal = ctx.accounts.receiver_dst_ata.amount;
    assert_amount_out(prev_bal, post_bal, amount_out_min)
}



#[derive(Accounts)]
pub struct SwapSolForTokens<'info> {
    #[account(mut)]
    pub user: Signer<'info>,
    #[account(address = NATIVE_MINT)]
    pub sol_mint: Account<'info, Mint>,
    #[account(
        mut,        
        associated_token::mint = sol_mint,
        associated_token::authority = user
    )]
    pub user_wsol_ata: Account<'info, TokenAccount>,
    #[account(mut)]
    pub receiver_dst_ata: Account<'info, TokenAccount>,
    #[account(
        mut, 
        associated_token::mint = sol_mint,
        associated_token::authority = UNIZEN
    )]
    pub unizen_wsol_ata: Account<'info, TokenAccount>,
    #[account(mut)]
    pub integrator_wsol_ata: Account<'info, TokenAccount>,
    pub jupiter_program: Program<'info, Jupiter>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}