pub const BudgetContext = struct {
    phase_budget_ns: i64,
    engine_elapsed_ns: i64,
    remaining_ns: i64,
    is_tick_frame: bool,
    tick_cost_ns: i64,
    safety_margin_ns: i64,

    pub const DEFAULT_SAFETY_MARGIN_NS: i64 = 500_000; // 0.5 ms

    pub fn safe_remaining(self: BudgetContext) i64 {
        return @max(0, self.remaining_ns - self.safety_margin_ns);
    }
};
