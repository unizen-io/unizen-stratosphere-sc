use anchor_lang::prelude::*;

#[constant]
pub const AUTHORITY_SEED: &[u8] = b"authority";

#[constant]
pub const WSOL_SEED: &[u8] = b"wsol";

#[constant]
pub const NATIVE_MINT: Pubkey = pubkey!("So11111111111111111111111111111111111111112");

#[constant]
pub const UNIZEN: Pubkey = pubkey!("6sp6GWkpHzzS8Mow5ZtyqG9DUVNXy5rXXZy1mNuRS1VJ");

#[constant]
pub const FEE_DENOM: u64 = 10000;
