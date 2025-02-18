use anchor_lang::prelude::*;
use anchor_spl::token::{Mint, Token};

use crate::{constants::*, helpers};

pub fn create_program_wsol_idempotent(ctx: Context<CreateWsolTokenIdempotent>) -> Result<()> {
    let authority_bump = ctx.bumps.program_authority.to_le_bytes();
    let wsol_bump = ctx.bumps.program_wsol.to_le_bytes();

    helpers::create_program_wsol_idempotent(
        ctx.accounts.program_authority.clone(),
        ctx.accounts.program_wsol.clone(),
        ctx.accounts.sol_mint.clone(),
        ctx.accounts.token_program.clone(),
        ctx.accounts.system_program.clone(),
        &authority_bump,
        &wsol_bump,
    )?;

    Ok(())
}

#[derive(Accounts)]
pub struct CreateWsolTokenIdempotent<'info> {
    #[account(mut, seeds = [AUTHORITY_SEED], bump)]
    pub program_authority: SystemAccount<'info>,
    /// CHECK: This may not be initialized yet.
    #[account(mut, seeds = [WSOL_SEED], bump)]
    pub program_wsol: UncheckedAccount<'info>,
    #[account(address = NATIVE_MINT)]
    pub sol_mint: Account<'info, Mint>,
    pub token_program: Program<'info, Token>,
    pub system_program: Program<'info, System>,
}
