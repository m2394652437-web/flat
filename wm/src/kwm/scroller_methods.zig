pub fn cycle_mfact(current: f32, candidate_mfacts: []const f32) f32 {
    if (candidate_mfacts.len == 0) return current;

    for (candidate_mfacts) |mfact| {
        if (mfact > current)
            return mfact;
    }
    return candidate_mfacts[0];
}
