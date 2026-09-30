-- Security advisor (0029): _cross_outlet_claims_enabled is an internal helper. Its only callers are
-- SECURITY DEFINER functions (claim_open_shift, claim_shift_swap, set_cross_outlet_claims,
-- _staff_can_claim_at), which run as the owner, so signed-in users don't need to call it directly.
revoke execute on function public._cross_outlet_claims_enabled(uuid) from public, anon, authenticated;
