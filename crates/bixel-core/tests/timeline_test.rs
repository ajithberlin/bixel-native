use bixel_core::document::AsepriteDoc;
use bixel_core::timeline::{LoopMode, TimelineController};

fn doc() -> AsepriteDoc {
    let mut d = AsepriteDoc::new(4, 4, &[]);
    for _ in 0..3 {
        d.add_frame(100);
    }
    d
}

#[test]
fn forward_loop_wraps() {
    let mut tl = TimelineController::with_document(doc());
    tl.set_fps(10.0, true);
    assert_eq!(tl.current_frame(), 0);
    assert_eq!(tl.next_frame(), 1);
    assert_eq!(tl.next_frame(), 2);
    assert_eq!(tl.next_frame(), 3);
    assert_eq!(tl.next_frame(), 0);
}

#[test]
fn reverse_loop() {
    let mut tl = TimelineController::with_document(doc());
    tl.set_loop_mode("reverse");
    tl.go_to_frame(0);
    assert_eq!(tl.next_frame(), 3);
}

#[test]
fn ping_pong_bounces() {
    let mut tl = TimelineController::with_document(doc());
    tl.set_loop_mode("ping-pong");
    tl.go_to_frame(0);
    assert_eq!(tl.next_frame(), 1);
    assert_eq!(tl.next_frame(), 2);
    assert_eq!(tl.next_frame(), 3);
    assert_eq!(tl.next_frame(), 2);
    assert_eq!(tl.next_frame(), 1);
    assert_eq!(tl.next_frame(), 0);
}

#[test]
fn tag_constrains_playback() {
    let mut d = doc();
    d.add_tag("walk", 1, 2, "#ffaa00");
    let mut tl = TimelineController::with_document(d);
    tl.set_active_tag(Some("walk".into()));
    tl.go_to_frame(0);
    assert_eq!(tl.current_frame(), 1);
    assert_eq!(tl.next_frame(), 2);
    assert_eq!(tl.next_frame(), 1);
}

#[test]
fn update_advances_by_duration() {
    let mut d = AsepriteDoc::new(4, 4, &[]);
    d.add_frame(100);
    d.add_frame(100);
    let mut tl = TimelineController::with_document(d);
    // frames: 0(125ms default) 1(100ms) 2(100ms)
    tl.update(130.0);
    assert_eq!(tl.current_frame(), 1);
    tl.update(100.0);
    assert_eq!(tl.current_frame(), 2);
}

#[test]
fn onion_skin_defaults() {
    let mut tl = TimelineController::with_document(doc());
    assert!(!tl.onion_skin().enabled);
    tl.toggle_onion_skin(true);
    assert!(tl.onion_skin().enabled);
}

#[test]
fn loop_mode_validation() {
    let mut tl = TimelineController::with_document(doc());
    tl.set_loop_mode("bogus");
    assert_eq!(tl.loop_mode(), LoopMode::Forward);
    tl.set_loop_mode("ping-pong");
    assert_eq!(tl.loop_mode(), LoopMode::PingPong);
}
