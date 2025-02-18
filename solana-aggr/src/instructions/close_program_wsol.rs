use anchor_lang::prelude::*;
use anchor_spl::token::Token;

use crate::{constants::*, helpers};

pub fn close_program_wsol(ctx: Context<CloseProgramWsol>) -> Result<()> {
    let authority_bump = ctx.bumps.program_authority.to_le_bytes();

    helpers::close_program_wsol(
        ctx.accounts.program_authority.clone(),
        ctx.accounts.program_wsol.clone(),
        ctx.accounts.receiver.clone(),
        ctx.accounts.token_program.clone(),
        ctx.accounts.system_program.clone(),
        &authority_bump,
    )
}

#[derive(Accounts)]
pub struct CloseProgramWsol<'info> {
    #[account(mut, seeds = [AUTHORITY_SEED], bump)]
    pub program_authority: SystemAccount<'info>,
    /// CHECK: This may not be initialized yet.
    #[account(mut, seeds = [WSOL_SEED], bump)]
    pub program_wsol: UncheckedAccount<'info>,
    #[account(mut)]
    pub receiver: SystemAccount<'info>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}
