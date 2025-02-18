use anchor_lang::prelude::*;

#[error_code]
pub enum ErrorCode {
    #[msg("The authority account provided is not a valid owner of WSOL account.")]
    IncorrectOwner,
    #[msg("Out amount lower than expected after swap.")]
    InvalidSwapAmount,
    #[msg("Subtraction resulted in underflow")]
    Underflow,
}
