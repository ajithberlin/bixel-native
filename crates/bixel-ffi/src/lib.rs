//! C ABI for the Bixel engine, consumed by Swift via a cbindgen-generated
//! header.
//!
//! Design rules (see the Swift side in `app/`):
//! * Opaque handles are `Arc<Mutex<_>>` behind `#[repr(C)]` token structs so
//!   they are thread-safe and can be shared between the document and its
//!   timeline. The C header sees only `struct BixelDoc;`-style opaque pointers.
//! * Bulk pixel data is written into caller-provided buffers (never allocated
//!   per-pixel, never crossing the FFI boundary repeatedly).
//! * Strings are returned as NUL-terminated `char*` and freed with
//!   [`bixel_string_free`].

#![allow(clippy::missing_safety_doc)]

use std::ffi::{c_char, CStr, CString};
use std::sync::{Arc, Mutex};

use bixel_core::color::Rgba;
use bixel_core::document::AsepriteDoc;
use bixel_core::palette;
use bixel_core::timeline::{LoopMode, TimelineController};

// ------------------------------------------------------------- opaque types

/// Opaque handle to a sprite document (`Arc<Mutex<AsepriteDoc>>`).
#[repr(C)]
pub struct BixelDoc {
    _private: [u8; 0],
}

/// Opaque handle to a tile layer (`Mutex<TileLayer>`).
#[repr(C)]
pub struct BixelTileLayer {
    _private: [u8; 0],
}

/// Opaque handle to an animation controller (`TimelineController<...>`).
#[repr(C)]
pub struct BixelTimeline {
    _private: [u8; 0],
}

#[doc(hidden)]
type RealDoc = Arc<Mutex<AsepriteDoc>>;
#[doc(hidden)]
type RealTileLayer = Mutex<bixel_core::tilemap::TileLayer>;
#[doc(hidden)]
type RealTimeline = TimelineController<Arc<Mutex<AsepriteDoc>>>;

#[doc(hidden)]
#[inline]
unsafe fn doc<'a>(ptr: *mut BixelDoc) -> &'a RealDoc {
    unsafe { &*(ptr as *const RealDoc) }
}

#[doc(hidden)]
#[inline]
unsafe fn doc_ref<'a>(ptr: *const BixelDoc) -> &'a RealDoc {
    unsafe { &*(ptr as *const RealDoc) }
}

#[doc(hidden)]
#[inline]
unsafe fn tilelayer<'a>(ptr: *mut BixelTileLayer) -> &'a mut RealTileLayer {
    unsafe { &mut *(ptr as *mut RealTileLayer) }
}

#[doc(hidden)]
#[inline]
unsafe fn tilelayer_ref<'a>(ptr: *const BixelTileLayer) -> &'a RealTileLayer {
    unsafe { &*(ptr as *const RealTileLayer) }
}

#[doc(hidden)]
#[inline]
unsafe fn timeline<'a>(ptr: *mut BixelTimeline) -> &'a mut RealTimeline {
    unsafe { &mut *(ptr as *mut RealTimeline) }
}

#[doc(hidden)]
#[inline]
unsafe fn timeline_ref<'a>(ptr: *const BixelTimeline) -> &'a RealTimeline {
    unsafe { &*(ptr as *const RealTimeline) }
}

// ---------------------------------------------------------------- helpers

fn arg_str(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned()
}

fn out_cstr(s: String) -> *mut c_char {
    CString::new(s).unwrap_or_default().into_raw()
}

/// Free a string returned by any `bixel_*` function that returns `char*`.
#[no_mangle]
pub unsafe extern "C" fn bixel_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        unsafe { drop(CString::from_raw(ptr)) };
    }
}

// ------------------------------------------------------------- color / rgba

#[repr(C)]
#[derive(Clone, Copy)]
pub struct BixelColor {
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

impl From<BixelColor> for Rgba {
    fn from(c: BixelColor) -> Self {
        Rgba::new(c.r, c.g, c.b, c.a)
    }
}

impl From<Rgba> for BixelColor {
    fn from(c: Rgba) -> Self {
        BixelColor { r: c.r, g: c.g, b: c.b, a: c.a }
    }
}

// -------------------------------------------------------------- document

#[no_mangle]
pub extern "C" fn bixel_doc_new(width: u32, height: u32) -> *mut BixelDoc {
    let real = Arc::new(Mutex::new(AsepriteDoc::new(
        width.max(1) as usize,
        height.max(1) as usize,
        &[],
    )));
    Box::into_raw(Box::new(real)) as *mut BixelDoc
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_free(ptr: *mut BixelDoc) {
    if !ptr.is_null() {
        unsafe { drop(Box::from_raw(ptr as *mut RealDoc)) };
    }
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_width(ptr: *const BixelDoc) -> u32 {
    unsafe { doc_ref(ptr) }.lock().unwrap().width as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_height(ptr: *const BixelDoc) -> u32 {
    unsafe { doc_ref(ptr) }.lock().unwrap().height as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_frame_count(ptr: *const BixelDoc) -> u32 {
    unsafe { doc_ref(ptr) }.lock().unwrap().frames.len() as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_layer_count(ptr: *const BixelDoc) -> u32 {
    unsafe { doc_ref(ptr) }.lock().unwrap().layers.len() as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_set_pixel(
    ptr: *mut BixelDoc,
    layer: u32,
    frame: u32,
    x: u32,
    y: u32,
    color: BixelColor,
) {
    unsafe { doc(ptr) }
        .lock()
        .unwrap()
        .set_pixel(layer as usize, frame as usize, x as usize, y as usize, color.into());
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_get_pixel(
    ptr: *const BixelDoc,
    layer: u32,
    frame: u32,
    x: u32,
    y: u32,
) -> BixelColor {
    unsafe { doc_ref(ptr) }
        .lock()
        .unwrap()
        .get_pixel(layer as usize, frame as usize, x as usize, y as usize)
        .into()
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_add_layer(ptr: *mut BixelDoc, name: *const c_char) -> u32 {
    let name = arg_str(name);
    unsafe { doc(ptr) }.lock().unwrap().add_layer(Some(&name)) as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_add_frame(ptr: *mut BixelDoc, duration_ms: u32) -> u32 {
    unsafe { doc(ptr) }.lock().unwrap().add_frame(duration_ms) as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_remove_frame(ptr: *mut BixelDoc, idx: u32) {
    unsafe { doc(ptr) }.lock().unwrap().remove_frame(idx as usize);
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_snapshot(ptr: *mut BixelDoc) {
    unsafe { doc(ptr) }.lock().unwrap().snapshot();
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_undo(ptr: *mut BixelDoc) -> bool {
    unsafe { doc(ptr) }.lock().unwrap().undo()
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_redo(ptr: *mut BixelDoc) -> bool {
    unsafe { doc(ptr) }.lock().unwrap().redo()
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_can_undo(ptr: *const BixelDoc) -> bool {
    unsafe { doc_ref(ptr) }.lock().unwrap().can_undo()
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_can_redo(ptr: *const BixelDoc) -> bool {
    unsafe { doc_ref(ptr) }.lock().unwrap().can_redo()
}

/// Composite a frame into a caller-provided RGBA buffer of
/// `width * height * 4` bytes.
#[no_mangle]
pub unsafe extern "C" fn bixel_doc_composite(ptr: *mut BixelDoc, frame: u32, out: *mut u8) {
    if out.is_null() {
        return;
    }
    let buf = unsafe { doc(ptr) }.lock().unwrap().composite_frame(frame as usize);
    unsafe {
        std::ptr::copy_nonoverlapping(buf.as_ptr(), out, buf.len());
    }
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_resize(ptr: *mut BixelDoc, width: u32, height: u32) {
    unsafe { doc(ptr) }
        .lock()
        .unwrap()
        .resize(width as usize, height as usize);
}

/// Load RGBA pixel data into `(layer, frame)`, resizing the document first.
#[no_mangle]
pub unsafe extern "C" fn bixel_doc_load_image(
    ptr: *mut BixelDoc,
    data: *const u8,
    width: u32,
    height: u32,
    layer: u32,
    frame: u32,
) {
    if data.is_null() {
        return;
    }
    let slice = unsafe { std::slice::from_raw_parts(data, (width * height * 4) as usize) };
    unsafe { doc(ptr) }
        .lock()
        .unwrap()
        .load_image_data(slice, width as usize, height as usize, layer as usize, frame as usize);
}

/// Place RGBA data on a new layer without resizing. Returns layer index, or -1.
/// `data` must point to `data_len` readable bytes. Records one undo snapshot.
#[no_mangle]
pub unsafe extern "C" fn bixel_doc_place_image(
    ptr: *mut BixelDoc, data: *const u8, data_len: usize,
    width: u32, height: u32, x: i32, y: i32, frame: u32, name: *const c_char,
) -> i32 {
    if ptr.is_null() || data.is_null() || data_len > 256 * 1024 * 1024 { return -1; }
    let expected = (width as usize).checked_mul(height as usize).and_then(|n| n.checked_mul(4));
    if expected != Some(data_len) || data_len == 0 { return -1; }
    let data = unsafe { std::slice::from_raw_parts(data, data_len) };
    let name = if name.is_null() { "Placed image" } else { unsafe { CStr::from_ptr(name) }.to_str().unwrap_or("Placed image") };
    unsafe { doc(ptr) }.lock().unwrap()
        .place_image_data(data, width as usize, height as usize, x, y, frame as usize, name)
        .map_or(-1, |index| index as i32)
}

/// Replace an RGBA region on an existing layer. Host owns undo snapshots.
/// Returns false for invalid input, unavailable layer, or no canvas overlap.
#[no_mangle]
pub unsafe extern "C" fn bixel_doc_stamp_image(
    ptr: *mut BixelDoc, data: *const u8, data_len: usize,
    width: u32, height: u32, x: i32, y: i32, layer: u32, frame: u32,
) -> bool {
    if ptr.is_null() || data.is_null() || data_len > 256 * 1024 * 1024 { return false; }
    let expected = (width as usize).checked_mul(height as usize).and_then(|n| n.checked_mul(4));
    if expected != Some(data_len) || data_len == 0 { return false; }
    let data = unsafe { std::slice::from_raw_parts(data, data_len) };
    unsafe { doc(ptr) }.lock().unwrap()
        .stamp_image_data(data, width as usize, height as usize, x, y, layer as usize, frame as usize)
        .is_ok()
}

/// Import a regular RGBA sheet to a new layer, starting at frame zero.
/// Cell size must match the canvas. Returns layer index, or -1; one undo step.
#[no_mangle]
pub unsafe extern "C" fn bixel_doc_import_sheet(
    ptr: *mut BixelDoc, data: *const u8, data_len: usize,
    width: u32, height: u32, cell_width: u32, cell_height: u32, name: *const c_char,
) -> i32 {
    if ptr.is_null() || data.is_null() || data_len > 256 * 1024 * 1024 { return -1; }
    let expected = (width as usize).checked_mul(height as usize).and_then(|n| n.checked_mul(4));
    if expected != Some(data_len) || data_len == 0 { return -1; }
    let data = unsafe { std::slice::from_raw_parts(data, data_len) };
    let name = if name.is_null() { "Imported sheet" } else { unsafe { CStr::from_ptr(name) }.to_str().unwrap_or("Imported sheet") };
    unsafe { doc(ptr) }.lock().unwrap()
        .import_sheet_data(data, width as usize, height as usize, cell_width as usize, cell_height as usize, name)
        .map_or(-1, |index| index as i32)
}

/// Rasterise a polyline stroke with a round brush (one FFI call per gesture).
#[no_mangle]
pub unsafe extern "C" fn bixel_doc_stroke(
    ptr: *mut BixelDoc,
    layer: u32,
    frame: u32,
    xs: *const u32,
    ys: *const u32,
    count: u32,
    color: BixelColor,
    radius: u32,
) {
    if xs.is_null() || ys.is_null() || count == 0 {
        return;
    }
    let xs = unsafe { std::slice::from_raw_parts(xs, count as usize) };
    let ys = unsafe { std::slice::from_raw_parts(ys, count as usize) };
    let points: Vec<(usize, usize)> = xs
        .iter()
        .zip(ys.iter())
        .map(|(&x, &y)| (x as usize, y as usize))
        .collect();
    unsafe { doc(ptr) }
        .lock()
        .unwrap()
        .draw_stroke(layer as usize, frame as usize, &points, color.into(), radius);
}

/// 4-way flood fill; returns the number of pixels changed.
#[no_mangle]
pub unsafe extern "C" fn bixel_doc_flood_fill(
    ptr: *mut BixelDoc,
    layer: u32,
    frame: u32,
    x: u32,
    y: u32,
    color: BixelColor,
) -> u32 {
    unsafe { doc(ptr) }
        .lock()
        .unwrap()
        .flood_fill(layer as usize, frame as usize, x as usize, y as usize, color.into())
        as u32
}

// ------------------------------------------------------------------ layers

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_layer_name(ptr: *const BixelDoc, idx: u32) -> *mut c_char {
    let doc = unsafe { doc_ref(ptr) }.lock().unwrap();
    let name = doc
        .layers
        .get(idx as usize)
        .map(|l| l.name.clone())
        .unwrap_or_default();
    out_cstr(name)
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_layer_visible(ptr: *const BixelDoc, idx: u32) -> bool {
    unsafe { doc_ref(ptr) }
        .lock()
        .unwrap()
        .layers
        .get(idx as usize)
        .map(|l| l.visible)
        .unwrap_or(true)
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_set_layer_visible(ptr: *mut BixelDoc, idx: u32, visible: bool) {
    let mut doc = unsafe { doc(ptr) }.lock().unwrap();
    if let Some(layer) = doc.layers.get_mut(idx as usize) {
        layer.visible = visible;
    }
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_remove_layer(ptr: *mut BixelDoc, idx: u32) {
    unsafe { doc(ptr) }.lock().unwrap().remove_layer(idx as usize);
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_rename_layer(ptr: *mut BixelDoc, idx: u32, name: *const c_char) {
    let name = arg_str(name);
    unsafe { doc(ptr) }
        .lock()
        .unwrap()
        .rename_layer(idx as usize, &name);
}

/// Move a layer from one stack position to another (0 = bottom).
#[no_mangle]
pub unsafe extern "C" fn bixel_doc_reorder_layer(ptr: *mut BixelDoc, from: u32, to: u32) {
    unsafe { doc(ptr) }
        .lock()
        .unwrap()
        .reorder_layer(from as usize, to as usize);
}

/// Layer opacity, 0.0..=1.0.
#[no_mangle]
pub unsafe extern "C" fn bixel_doc_layer_opacity(ptr: *const BixelDoc, idx: u32) -> f32 {
    unsafe { doc_ref(ptr) }
        .lock()
        .unwrap()
        .layers
        .get(idx as usize)
        .map(|l| l.opacity)
        .unwrap_or(1.0)
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_set_layer_opacity(ptr: *mut BixelDoc, idx: u32, opacity: f32) {
    if let Some(layer) = unsafe { doc(ptr) }.lock().unwrap().layers.get_mut(idx as usize) {
        layer.opacity = opacity.clamp(0.0, 1.0);
    }
}

/// Copy one cel's packed RGBA into `out` (`width * height * 4` bytes). Missing
/// cels yield a fully transparent buffer.
#[no_mangle]
pub unsafe extern "C" fn bixel_doc_cel_rgba(ptr: *const BixelDoc, layer: u32, frame: u32, out: *mut u8) {
    if out.is_null() {
        return;
    }
    let doc = unsafe { doc_ref(ptr) }.lock().unwrap();
    let len = doc.width * doc.height * 4;
    let empty = vec![0u8; len];
    let data: &[u8] = doc
        .layers
        .get(layer as usize)
        .and_then(|l| l.cels.get(frame as usize))
        .and_then(|c| c.as_ref())
        .map(|c| c.data.as_slice())
        .filter(|d| d.len() == len)
        .unwrap_or(&empty);
    unsafe { std::ptr::copy_nonoverlapping(data.as_ptr(), out, len) };
}

/// Frame duration in milliseconds.
#[no_mangle]
pub unsafe extern "C" fn bixel_doc_frame_duration(ptr: *const BixelDoc, idx: u32) -> u32 {
    unsafe { doc_ref(ptr) }
        .lock()
        .unwrap()
        .frames
        .get(idx as usize)
        .map(|f| f.duration_ms)
        .unwrap_or(0)
}

#[no_mangle]
pub unsafe extern "C" fn bixel_doc_set_frame_duration(ptr: *mut BixelDoc, idx: u32, duration_ms: u32) {
    if let Some(frame) = unsafe { doc(ptr) }.lock().unwrap().frames.get_mut(idx as usize) {
        frame.duration_ms = duration_ms.max(1);
    }
}

// --------------------------------------------------------------- palette

#[no_mangle]
pub extern "C" fn bixel_hex_to_rgba(hex: *const c_char) -> BixelColor {
    palette::hex_to_rgba(&arg_str(hex)).into()
}

#[no_mangle]
pub extern "C" fn bixel_rgba_to_hex(color: BixelColor) -> *mut c_char {
    out_cstr(Rgba::from(color).to_hex())
}

#[no_mangle]
pub extern "C" fn bixel_nearest_color(hex: *const c_char, palette_kind: u32) -> BixelColor {
    let color = palette::hex_to_rgba(&arg_str(hex));
    let presets: &[&str] = match palette_kind {
        1 => &palette::PICO8,
        2 => &palette::GAMEBOY,
        _ => &palette::DB32,
    };
    let parsed = palette::parse_palette(presets);
    match palette::find_nearest_index(color, &parsed) {
        Some(i) => parsed[i].into(),
        None => color.into(),
    }
}

#[no_mangle]
pub extern "C" fn bixel_palette_size(kind: u32) -> u32 {
    match kind {
        1 => palette::PICO8.len() as u32,
        2 => palette::GAMEBOY.len() as u32,
        _ => palette::DB32.len() as u32,
    }
}

/// Fill `out` with the packed RGBA of the preset palette (kind as above).
#[no_mangle]
pub unsafe extern "C" fn bixel_palette_rgba(kind: u32, out: *mut u8) {
    if out.is_null() {
        return;
    }
    let presets: &[&str] = match kind {
        1 => &palette::PICO8,
        2 => &palette::GAMEBOY,
        _ => &palette::DB32,
    };
    let parsed = palette::parse_palette(presets);
    unsafe {
        for (i, c) in parsed.iter().enumerate() {
            *out.add(i * 4) = c.r;
            *out.add(i * 4 + 1) = c.g;
            *out.add(i * 4 + 2) = c.b;
            *out.add(i * 4 + 3) = c.a;
        }
    }
}

// -------------------------------------------------------------- tile layer

#[no_mangle]
pub extern "C" fn bixel_tilelayer_new(width: u32, height: u32) -> *mut BixelTileLayer {
    Box::into_raw(Box::new(Mutex::new(bixel_core::tilemap::TileLayer::new(
        width as usize,
        height as usize,
    )))) as *mut BixelTileLayer
}

#[no_mangle]
pub unsafe extern "C" fn bixel_tilelayer_free(ptr: *mut BixelTileLayer) {
    if !ptr.is_null() {
        unsafe { drop(Box::from_raw(ptr as *mut RealTileLayer)) };
    }
}

#[no_mangle]
pub unsafe extern "C" fn bixel_tilelayer_get(ptr: *const BixelTileLayer, x: i32, y: i32) -> u32 {
    let l = unsafe { tilelayer_ref(ptr) }.lock().unwrap();
    bixel_core::tilemap::get_tile(&l, x as isize, y as isize)
}

#[no_mangle]
pub unsafe extern "C" fn bixel_tilelayer_set(
    ptr: *mut BixelTileLayer,
    x: i32,
    y: i32,
    raw: u32,
) -> bool {
    let mut l = unsafe { tilelayer(ptr) }.lock().unwrap();
    bixel_core::tilemap::set_tile(&mut l, x as isize, y as isize, raw)
}

#[no_mangle]
pub unsafe extern "C" fn bixel_tilelayer_flood(
    ptr: *mut BixelTileLayer,
    x: i32,
    y: i32,
    raw: u32,
) -> u32 {
    let mut l = unsafe { tilelayer(ptr) }.lock().unwrap();
    bixel_core::tilemap::flood_fill(&mut l, x as isize, y as isize, raw).len() as u32
}

// --------------------------------------------------------------- timeline

#[no_mangle]
pub unsafe extern "C" fn bixel_timeline_new(ptr: *mut BixelDoc) -> *mut BixelTimeline {
    let doc_handle = unsafe { Arc::clone(doc_ref(ptr)) };
    Box::into_raw(Box::new(TimelineController::new(doc_handle))) as *mut BixelTimeline
}

#[no_mangle]
pub unsafe extern "C" fn bixel_timeline_free(ptr: *mut BixelTimeline) {
    if !ptr.is_null() {
        unsafe { drop(Box::from_raw(ptr as *mut RealTimeline)) };
    }
}

#[no_mangle]
pub unsafe extern "C" fn bixel_timeline_update(ptr: *mut BixelTimeline, delta_ms: f32) -> u32 {
    unsafe { timeline(ptr) }.update(delta_ms) as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_timeline_next(ptr: *mut BixelTimeline) -> u32 {
    unsafe { timeline(ptr) }.next_frame() as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_timeline_prev(ptr: *mut BixelTimeline) -> u32 {
    unsafe { timeline(ptr) }.prev_frame() as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_timeline_go_to(ptr: *mut BixelTimeline, frame: u32) -> u32 {
    unsafe { timeline(ptr) }.go_to_frame(frame as usize) as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_timeline_set_fps(ptr: *mut BixelTimeline, fps: f32) {
    unsafe { timeline(ptr) }.set_fps(fps, true);
}

#[no_mangle]
pub unsafe extern "C" fn bixel_timeline_set_loop_mode(ptr: *mut BixelTimeline, mode: u32) {
    let mode = match mode {
        1 => "reverse",
        2 => "ping-pong",
        _ => "forward",
    };
    unsafe { timeline(ptr) }.set_loop_mode(mode);
}

#[no_mangle]
pub unsafe extern "C" fn bixel_timeline_set_active_tag(
    ptr: *mut BixelTimeline,
    name: *const c_char,
) {
    let name = arg_str(name);
    let tag = if name.is_empty() { None } else { Some(name) };
    unsafe { timeline(ptr) }.set_active_tag(tag);
}

#[no_mangle]
pub unsafe extern "C" fn bixel_timeline_play(ptr: *mut BixelTimeline) {
    unsafe { timeline(ptr) }.play();
}

#[no_mangle]
pub unsafe extern "C" fn bixel_timeline_pause(ptr: *mut BixelTimeline) {
    unsafe { timeline(ptr) }.pause();
}

#[no_mangle]
pub unsafe extern "C" fn bixel_timeline_current_frame(ptr: *const BixelTimeline) -> u32 {
    unsafe { timeline_ref(ptr) }.current_frame() as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_timeline_loop_mode(ptr: *const BixelTimeline) -> u32 {
    match unsafe { timeline_ref(ptr) }.loop_mode() {
        LoopMode::Forward => 0,
        LoopMode::Reverse => 1,
        LoopMode::PingPong => 2,
    }
}

// --------------------------------------------------------------------- AI

use std::sync::OnceLock;

use bixel_ai::native_stream::{NativeEvent, NativeRequest};

static AI_TURN: Mutex<()> = Mutex::new(());

static AI_ENGINE: OnceLock<Result<bixel_ai::GooseAgent, String>> = OnceLock::new();

fn ai_engine() -> Result<&'static bixel_ai::GooseAgent, String> {
    AI_ENGINE
        .get_or_init(|| {
            let settings = bixel_ai::AiSettings::from_env_file();
            bixel_ai::GooseAgent::new(settings).map_err(|e| e.to_string())
        })
        .as_ref()
        .map_err(|e| e.clone())
}

static IMAGE_GEN: OnceLock<bixel_ai::image_gen::ImageGen> = OnceLock::new();

fn image_gen() -> &'static bixel_ai::image_gen::ImageGen {
    IMAGE_GEN
        .get_or_init(|| bixel_ai::image_gen::ImageGen::new(&bixel_ai::AiSettings::from_env_file()))
}

/// Load a `.env` file into the process environment (`null`/empty = auto-detect).
#[no_mangle]
pub extern "C" fn bixel_ai_load_env(path: *const c_char) {
    let path = arg_str(path);
    let path = if path.is_empty() { None } else { Some(std::path::PathBuf::from(path)) };
    bixel_core::config::load_env(path.as_deref(), false);
}

/// Lightweight configuration check; provider/runtime startup belongs on the worker thread.
#[no_mangle]
pub extern "C" fn bixel_ai_available() -> bool {
    bixel_ai::AiSettings::from_env_file().has_key()
}

/// JSON array of the available skills (id, name, description, params schema).
#[no_mangle]
pub extern "C" fn bixel_ai_list_skills() -> *mut c_char {
    let specs = bixel_ai::skills::Skills::specs();
    let json = serde_json::to_string(&specs).unwrap_or_else(|_| "[]".into());
    out_cstr(json)
}

const AI_SYSTEM_PROMPT: &str =
    "You are Bixel, an AI assistant for a 2D pixel-art game studio. Be concise and helpful.";

/// Blocking text chat with the configured text model.
///
/// `system` may be null/empty to use a default studio prompt. Returns a
/// `char*` (free with [`bixel_string_free`]), or null on error.
#[no_mangle]
pub extern "C" fn bixel_ai_chat(prompt: *const c_char, system: *const c_char) -> *mut c_char {
    let prompt = arg_str(prompt);
    if prompt.trim().is_empty() {
        return std::ptr::null_mut();
    }
    let system = arg_str(system);
    let system = if system.trim().is_empty() {
        AI_SYSTEM_PROMPT.to_string()
    } else {
        system
    };
    let Ok(agent) = ai_engine() else { return std::ptr::null_mut(); };
    let base = std::env::temp_dir().join("bixel-assistant");
    let request = NativeRequest {
        prompt,
        system,
        base: base.to_string_lossy().into_owned(),
        images: vec![],
    };
    let mut text = String::new();
    let result = agent.chat_stream(request, |event| {
        if let NativeEvent::Text { delta, .. } = event {
            text.push_str(&delta);
        }
        true
    });
    match result {
        Ok(()) if !text.trim().is_empty() => out_cstr(text),
        _ => std::ptr::null_mut(),
    }
}

/// Stream one agent turn. JSON event strings are borrowed for the callback duration.
/// The callback runs synchronously on the calling thread; false requests cancellation.
/// `context` remains owned by the caller and must live until this function returns.
#[no_mangle]
pub extern "C" fn bixel_ai_chat_stream(
    request_json: *const c_char,
    callback: Option<extern "C" fn(*const c_char, *mut std::ffi::c_void) -> bool>,
    context: *mut std::ffi::c_void,
) -> bool {
    let Some(callback) = callback else { return false; };
    let emit = |event: NativeEvent| {
        let json = serde_json::to_string(&event).unwrap_or_default();
        let Ok(value) = std::ffi::CString::new(json) else { return false; };
        callback(value.as_ptr(), context)
    };
    let _turn = AI_TURN.lock().unwrap();
    let result = (|| {
        let request: NativeRequest = serde_json::from_str(&arg_str(request_json)).map_err(|e| e.to_string())?;
        ai_engine()?.chat_stream(request, emit).map_err(|e| e.to_string())
    })();
    if let Err(message) = result {
        emit(NativeEvent::Error { message });
        return false;
    }
    true
}

/// Public model labels only. Credentials never cross this boundary.
#[no_mangle]
pub extern "C" fn bixel_ai_model_info() -> *mut c_char {
    let settings = bixel_ai::AiSettings::from_env_file();
    out_cstr(serde_json::json!({
        "text": settings.text_model, "vision": settings.vision_model,
        "image": settings.image_model, "available": settings.has_key(),
    }).to_string())
}

/// Forget the current chat conversation so the next `bixel_ai_chat` starts
/// fresh with no prior context.
#[no_mangle]
pub extern "C" fn bixel_ai_chat_reset() {
    if let Ok(agent) = ai_engine() {
        agent.reset();
    }
}

// -- buffer helpers (header-prefixed allocation, freed by bixel_ai_free_buffer)

fn alloc_buffer(v: Vec<u8>) -> *mut u8 {
    let mut buf = Vec::with_capacity(v.len() + 8);
    buf.extend_from_slice(&(v.len() as u64).to_le_bytes());
    buf.extend_from_slice(&v);
    let mut boxed = buf.into_boxed_slice();
    let data_ptr = unsafe { boxed.as_mut_ptr().add(8) };
    std::mem::forget(boxed);
    data_ptr
}

/// Write `out_len` (when non-null) and return a header-prefixed buffer.
unsafe fn return_bytes(v: Vec<u8>, out_len: *mut u64) -> *mut u8 {
    if !out_len.is_null() {
        unsafe { *out_len = v.len() as u64 };
    }
    alloc_buffer(v)
}

/// Free a buffer returned by a `bixel_ai_*` function.
#[no_mangle]
pub unsafe extern "C" fn bixel_ai_free_buffer(ptr: *mut u8) {
    if ptr.is_null() {
        return;
    }
    let base = ptr.sub(8);
    let len = unsafe { *(base as *const u64) } as usize;
    let slice = unsafe { std::slice::from_raw_parts_mut(base, len + 8) };
    unsafe { drop(Box::from_raw(slice as *mut [u8])) };
}

// -- model-backed skills (blocking; return PNG bytes via the length out-param)

#[no_mangle]
pub unsafe extern "C" fn bixel_ai_generate_art(
    prompt: *const c_char,
    out_len: *mut u64,
) -> *mut u8 {
    let prompt = arg_str(prompt);
    match image_gen().generate_image(&prompt, None) {
        Ok(img) => match bixel_ai::image::encode_png(&img) {
            Ok(png) => unsafe { return_bytes(png, out_len) },
            Err(_) => std::ptr::null_mut(),
        },
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn bixel_ai_next_frame(
    png_in: *const u8,
    in_len: u64,
    prompt: *const c_char,
    out_len: *mut u64,
) -> *mut u8 {
    if png_in.is_null() {
        return std::ptr::null_mut();
    }
    let bytes = unsafe { std::slice::from_raw_parts(png_in, in_len as usize) };
    let Ok(current) = bixel_ai::image::decode_png(bytes) else {
        return std::ptr::null_mut();
    };
    let prompt = arg_str(prompt);
    match image_gen().generate_image(&prompt, Some(&current)) {
        Ok(img) => match bixel_ai::image::encode_png(&img) {
            Ok(png) => unsafe { return_bytes(png, out_len) },
            Err(_) => std::ptr::null_mut(),
        },
        Err(_) => std::ptr::null_mut(),
    }
}

// -- deterministic skills (operate on caller RGBA buffers in place)

#[no_mangle]
pub unsafe extern "C" fn bixel_ai_compress_rgba(
    data: *const u8,
    width: u32,
    height: u32,
    bits: u8,
    out: *mut u8,
) {
    if data.is_null() || out.is_null() {
        return;
    }
    let (w, h) = (width as usize, height as usize);
    let slice = unsafe { std::slice::from_raw_parts(data, w * h * 4) };
    let img = bixel_ai::image::RgbaImage::from_rgba(w, h, slice.to_vec());
    let result = bixel_ai::image::compress_to_bits(&img, bits);
    unsafe { std::ptr::copy_nonoverlapping(result.data.as_ptr(), out, w * h * 4) };
}

#[no_mangle]
pub unsafe extern "C" fn bixel_ai_remove_bg_rgba(
    data: *const u8,
    width: u32,
    height: u32,
    tolerance: f32,
    out: *mut u8,
) {
    if data.is_null() || out.is_null() {
        return;
    }
    let (w, h) = (width as usize, height as usize);
    let slice = unsafe { std::slice::from_raw_parts(data, w * h * 4) };
    let img = bixel_ai::image::RgbaImage::from_rgba(w, h, slice.to_vec());
    let result = bixel_ai::image::remove_background(&img, tolerance);
    unsafe { std::ptr::copy_nonoverlapping(result.data.as_ptr(), out, w * h * 4) };
}

// -- generic skill runner (any registered skill, deterministic or model-backed)

/// Run any registered skill by id, passing optional input PNG bytes and a JSON
/// params object. Returns a JSON string (free with [`bixel_string_free`]) of the
/// shape `{ "text": "...", "image": "<base64 png>", "frames": ["<base64>", ...] }`,
/// or `{"error": "..."}` on failure.
#[no_mangle]
pub unsafe extern "C" fn bixel_ai_run_skill(
    skill_id: *const c_char,
    params_json: *const c_char,
    png_in: *const u8,
    in_len: u64,
) -> *mut c_char {
    let id = arg_str(skill_id);
    let Some(kind) = bixel_ai::skills::SkillKind::from_id(&id) else {
        return out_cstr(r#"{"error":"unknown skill"}"#.to_string());
    };

    let params: serde_json::Value = match serde_json::from_str(&arg_str(params_json)) {
        Ok(v) => v,
        Err(_) => serde_json::json!({}),
    };

    let image = if !png_in.is_null() && in_len > 0 {
        let bytes = unsafe { std::slice::from_raw_parts(png_in, in_len as usize) };
        bixel_ai::image::decode_any(&bytes).ok()
    } else {
        None
    };

    let input = bixel_ai::skills::SkillInput {
        prompt: String::new(),
        image,
        images: vec![],
        params,
    };

    let engine = if kind.is_deterministic() { None } else { Some(image_gen()) };
    let output = bixel_ai::skills::Skills::run(engine, kind, input);
    match output {
        Ok(o) => out_cstr(bixel_ai::skills::skill_output_to_json(&o)),
        Err(e) => out_cstr(format!(
            r#"{{"error":{}}}"#,
            serde_json::to_string(&e.to_string()).unwrap_or_else(|_| r#""skill failed""#.into())
        )),
    }
}

/// Host-owned filesystem operations. Returns {value:...} or {error:...}; free with bixel_string_free.
#[no_mangle]
pub extern "C" fn bixel_storage_request(base: *const c_char, request: *const c_char) -> *mut c_char {
    let result = serde_json::from_str(&arg_str(request)).map_err(|e| e.to_string())
        .and_then(|value| bixel_core::storage::request(std::path::Path::new(&arg_str(base)), &value));
    out_cstr(match result {
        Ok(value) => serde_json::json!({"value":value}),
        Err(error) => serde_json::json!({"error":error}),
    }.to_string())
}

/// Persist a complete document atomically under an explicit root, off the UI thread.
/// Returns null on success or an owned error string.
#[no_mangle]
pub unsafe extern "C" fn bixel_doc_save(ptr: *const BixelDoc, base: *const c_char, path: *const c_char) -> *mut c_char {
    if ptr.is_null() { return out_cstr("Missing document".into()); }
    // Clone under the document lock, then release it before serialization and disk I/O.
    let snapshot = unsafe { doc_ref(ptr) }.lock().unwrap().persistence_copy();
    let result = snapshot.to_json().and_then(|text| bixel_core::storage::write(std::path::Path::new(&arg_str(base)), &arg_str(path), text.as_bytes()));
    match result { Ok(()) => std::ptr::null_mut(), Err(e) => out_cstr(e) }
}

/// Restore a validated layered document. Null signals malformed input.
#[no_mangle]
pub extern "C" fn bixel_doc_from_json(json: *const c_char) -> *mut BixelDoc {
    match AsepriteDoc::from_json(&arg_str(json)) {
        Ok(document) => Box::into_raw(Box::new(Arc::new(Mutex::new(document)))) as *mut BixelDoc,
        Err(_) => std::ptr::null_mut(),
    }
}

/// Write a caller-owned artifact buffer beneath the project root. Returns an owned error or null.
#[no_mangle]
pub unsafe extern "C" fn bixel_storage_write(base: *const c_char, path: *const c_char, bytes: *const u8, len: u64) -> *mut c_char {
    if bytes.is_null() || len > isize::MAX as u64 { return out_cstr("Invalid artifact buffer".into()); }
    let data = unsafe { std::slice::from_raw_parts(bytes, len as usize) };
    match bixel_core::storage::write(std::path::Path::new(&arg_str(base)), &arg_str(path), data) {
        Ok(()) => std::ptr::null_mut(), Err(e) => out_cstr(e),
    }
}
