use anchor_lang::prelude::*;
use anchor_spl::token::{Mint, Token, TokenAccount};

use crate::{constants::*, helpers};

pub fn take_integrator_fee(
    ctx: Context<TakeIntegratorFee>,
    amount_in: u64,
    fee_percent: u64,
    share_percent: u64,
) -> Result<()> {
    helpers::take_integrator_fee(
      helpers::AccountsForFee {
            user: ctx.accounts.user.clone(),
            token_program: ctx.accounts.token_program.clone(),
            user_token_account: ctx.accounts.user_ata.clone(),
            unizen_token_account: ctx.accounts.unizen_ata.clone(),
            integrator_token_account: ctx.accounts.integrator_ata.clone(),
        },
        amount_in,
        fee_percent,
        share_percent,
    )?;

    Ok(())
}

#[derive(Accounts)]
pub struct TakeIntegratorFee<'info> {
  pub user: Signer<'info>,
  #[account(mut)]
  pub token: Account<'info, Mint>,
  #[account(mut)]
  pub user_ata: Account<'info, TokenAccount>,
  #[account(
      mut,        
      associated_token::mint = token,
      associated_token::authority = UNIZEN
  )]
  pub unizen_ata: Account<'info, TokenAccount>,
  #[account(mut)]
  pub integrator_ata: Account<'info, TokenAccount>,
  pub token_program: Program<'info, Token>,
  pub system_program: Program<'info, System>,
}