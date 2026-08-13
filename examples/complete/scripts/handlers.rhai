// Complete Example - UI Event Handlers
//
// Navigation is declarative: the sidenav <nav-link>s drive the <router> in
// <app-content>, so there is no page-switching handler here.

// Reset counter button handler
fn on_reset_counter(component_id, event_data) {
    set_data("app.counter", 0);
}

// Toggle auto-refresh
fn on_toggle_refresh(component_id, event_data) {
    let current = get_data("app.auto_refresh");
    let new_val = if current == true { false } else { true };
    set_data("app.auto_refresh", new_val);
}
