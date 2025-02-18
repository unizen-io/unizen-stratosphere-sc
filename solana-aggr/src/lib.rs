use anchor_lang::prelude::*;

mod constants;
mod errors;
mod helpers;
mod instructions;

declare_id!("BUCtBoPAL3YDq7sv5LXQeCF977862G4AmDqgf56qHSTM");

#[program]
pub mod unizen_aggr {
    pub use super::instructions::*;
    use super::*;

    pub fn swap_tokens_for_sol(
        ctx: Context<SwapTokensForSol>,
        amount_in: u64,
        amount_out_min: u64,
        fee_percent: u64,
        share_percent: u64,
        data: Vec<u8>,
    ) -> Result<()> {
        instructions::swap_tokens_for_sol(
            ctx,
            amount_in,
            amount_out_min,
            fee_percent,
            share_percent,
            data,
        )
    }

    pub fn swap_sol_for_tokens(
        ctx: Context<SwapSolForTokens>,
        amount_in: u64,
        amount_out_min: u64,
        fee_percent: u64,
        share_percent: u64,
        data: Vec<u8>,
    ) -> Result<()> {
        instructions::swap_sol_for_tokens(
            ctx,
            amount_in,
            amount_out_min,
            fee_percent,
            share_percent,
            data,
        )
    }

    pub fn swap_tokens_for_tokens(
        ctx: Context<SwapTokensForTokens>,
        amount_in: u64,
        amount_out_min: u64,
        fee_percent: u64,
        share_percent: u64,
        data: Vec<u8>,
    ) -> Result<()> {
        instructions::swap_tokens_for_tokens(
            ctx,
            amount_in,
            amount_out_min,
            fee_percent,
            share_percent,
            data,
        )
    }

    pub fn take_integrator_fee(
        ctx: Context<TakeIntegratorFee>,
        amount_in: u64,
        fee_percent: u64,
        share_percent: u64,
    ) -> Result<()> {
        instructions::take_integrator_fee(ctx, amount_in, fee_percent, share_percent)
    }

    pub fn create_program_wsol_idempotent(ctx: Context<CreateWsolTokenIdempotent>) -> Result<()> {
        instructions::create_program_wsol_idempotent(ctx)
    }

    pub fn close_program_wsol(ctx: Context<CloseProgramWsol>) -> Result<()> {
        instructions::close_program_wsol(ctx)
    }
}
