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

/// Opaque handle to a tile map (`Arc<Mutex<TileMap>>`).
#[repr(C)]
pub struct BixelMap {
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
type RealMap = Arc<Mutex<bixel_core::map::TileMap>>;
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
unsafe fn map<'a>(ptr: *mut BixelMap) -> &'a RealMap {
    unsafe { &*(ptr as *const RealMap) }
}

#[doc(hidden)]
#[inline]
unsafe fn map_ref<'a>(ptr: *const BixelMap) -> &'a RealMap {
    unsafe { &*(ptr as *const RealMap) }
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
pub unsafe extern "C" fn bixel_doc_reorder_frame(ptr: *mut BixelDoc, from: u32, to: u32) {
    unsafe { doc(ptr) }.lock().unwrap().reorder_frame(from as usize, to as usize);
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

/// Pack composited frames row-major into a caller-owned RGBA buffer.
/// Buffer length must exactly match the packed dimensions; capped at 256 MB.
#[no_mangle]
pub unsafe extern "C" fn bixel_doc_pack_frames(
    ptr: *const BixelDoc, columns: u32, out: *mut u8, out_len: usize,
) -> bool {
    if ptr.is_null() || out.is_null() || columns == 0 || out_len > 256 * 1024 * 1024 { return false; }
    let document = unsafe { doc_ref(ptr) }.lock().unwrap();
    let columns = columns as usize;
    let rows = document.frames.len() / columns + usize::from(document.frames.len() % columns != 0);
    let expected = document.width.checked_mul(columns)
        .and_then(|w| document.height.checked_mul(rows).and_then(|h| w.checked_mul(h)))
        .and_then(|n| n.checked_mul(4));
    if expected != Some(out_len) || out_len == 0 { return false; }
    match document.pack_frames(columns) {
        Ok((pixels, _, _)) => {
            unsafe { std::ptr::copy_nonoverlapping(pixels.as_ptr(), out, pixels.len()); }
            true
        }
        Err(_) => false,
    }
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

/// Transform a rectangular selection in-place with nearest-neighbor sampling.
/// Rotation is clockwise quarter turns; the operation records one undo step.
#[no_mangle]
pub unsafe extern "C" fn bixel_doc_transform_rect(
    ptr: *mut BixelDoc, layer: u32, frame: u32,
    sx: u32, sy: u32, sw: u32, sh: u32,
    dx: i32, dy: i32, dw: u32, dh: u32, rotation: u32,
) -> bool {
    if ptr.is_null() { return false; }
    let mut document = unsafe { doc(ptr) }.lock().unwrap();
    if document.transform_rect(layer as usize, frame as usize, sx as usize, sy as usize,
                               sw as usize, sh as usize, dx, dy, dw as usize, dh as usize, rotation).is_err() {
        return false;
    }
    true
}

/// Transform a rectangular selection with an arbitrary clockwise angle in
/// radians using nearest-neighbor sampling. The destination rectangle should
/// contain the rotated source bounds.
#[no_mangle]
pub unsafe extern "C" fn bixel_doc_transform_rect_angle(
    ptr: *mut BixelDoc, layer: u32, frame: u32,
    sx: u32, sy: u32, sw: u32, sh: u32,
    dx: i32, dy: i32, dw: u32, dh: u32, angle: f64,
) -> bool {
    if ptr.is_null() || !angle.is_finite() { return false; }
    let mut document = unsafe { doc(ptr) }.lock().unwrap();
    if document.transform_rect_angle(layer as usize, frame as usize, sx as usize, sy as usize,
                                     sw as usize, sh as usize, dx, dy, dw as usize, dh as usize,
                                     angle).is_err() {
        return false;
    }
    true
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

use bixel_ai::native_stream::{NativeEvent, NativeRequest};
use bixel_ai::{ConnectionConfig, GooseAgent, ModelReadiness};

static AI_TURN: Mutex<()> = Mutex::new(());

/// Reconfigurable holder for the shared agent (one per process). Replaces the
/// old non-resettable `OnceLock`: connect/disconnect swap the connection
/// underneath the agent; dropping it resets sessions too.
struct AiState {
    agent: Option<std::sync::Arc<GooseAgent>>,
    last_error: Option<String>,
}

static AI_STATE: Mutex<AiState> = Mutex::new(AiState { agent: None, last_error: None });

/// Connect (or reconnect) the shared agent with a new credential set.
fn connect_agent(cfg: ConnectionConfig) -> Result<std::sync::Arc<GooseAgent>, String> {
    let mut state = AI_STATE.lock().unwrap();
    let agent = match &state.agent {
        Some(agent) => agent.clone(),
        None => {
            let agent =
                std::sync::Arc::new(GooseAgent::new().map_err(|e| e.to_string())?);
            state.agent = Some(agent.clone());
            agent
        }
    };
    match agent.connect(cfg) {
        Ok(_) => {
            state.last_error = None;
            Ok(agent)
        }
        Err(e) => {
            let message = e.to_string();
            state.last_error = Some(message.clone());
            Err(message)
        }
    }
}

/// The shared agent, usable only after an explicit UI connect.
fn ai_agent() -> Result<std::sync::Arc<GooseAgent>, String> {
    let state = AI_STATE.lock().unwrap();
    match &state.agent {
        Some(agent) if agent.handle().is_some() => Ok(agent.clone()),
        _ => Err("AI provider is not connected".to_string()),
    }
}

/// Connection status as a JSON value. Credentials never appear here — only a
/// masked `…last4` label. Until the UI connects, the models shown are the
/// built-in defaults the next connect would use.
fn connection_status_json() -> serde_json::Value {
    let (connected_cfg, readiness, connected) = {
        let state = AI_STATE.lock().unwrap();
        match &state.agent {
            Some(agent) if agent.handle().is_some() => {
                let handle = agent.handle().unwrap();
                (Some(handle.config.clone()), agent.readiness(), true)
            }
            _ => (None, None, false),
        }
    };
    let active = connected_cfg.unwrap_or_default();
    let readiness_json = |r: Option<&ModelReadiness>| {
        serde_json::json!({
            "text": r.map(|r| serde_json::to_value(&r.text).unwrap()),
            "vision": r.map(|r| serde_json::to_value(&r.vision).unwrap()),
            "image": r.map(|r| serde_json::to_value(&r.image).unwrap()),
        })
    };
    let image_model = readiness
        .as_ref()
        .map(|r| r.image.model.clone())
        .filter(|model| !model.is_empty())
        .unwrap_or_else(|| active.models.image.clone());
    let image_source = connected.then(|| match active.provider {
        bixel_ai::ProviderChoice::ChatgptCodex => "codex_hosted",
        bixel_ai::ProviderChoice::OpenRouter => "openrouter_model",
    });
    serde_json::json!({
        "connected": connected,
        "provider": active.provider.goose_name(),
        "provider_label": active.provider.label(),
        "key": active.masked_key(),
        "models": {
            "text": active.models.text,
            "vision": active.models.vision,
            "image": image_model,
        },
        "image_source": image_source,
        "base_url": active.base_url,
        "readiness": readiness_json(readiness.as_ref()),
    })
}

/// Load a `.env` file into the process environment (`null`/empty = auto-detect).
#[no_mangle]
pub extern "C" fn bixel_ai_load_env(path: *const c_char) {
    let path = arg_str(path);
    let path = if path.is_empty() { None } else { Some(std::path::PathBuf::from(path)) };
    bixel_core::config::load_env(path.as_deref(), false);
}

/// Connect the assistant through goose's provider API. `config_json` is a
/// [`ConnectionConfig`] (provider, api_key, models, base_url); keys are
/// write-only — they are stored in goose's secret store and never returned.
/// Returns null on success or an owned error string.
#[no_mangle]
pub extern "C" fn bixel_ai_connect(config_json: *const c_char) -> *mut c_char {
    let cfg: ConnectionConfig = match serde_json::from_str(&arg_str(config_json)) {
        Ok(cfg) => cfg,
        Err(e) => return out_cstr(format!("invalid connection config: {e}")),
    };
    match connect_agent(cfg) {
        Ok(_) => std::ptr::null_mut(),
        Err(e) => out_cstr(e),
    }
}

/// Drop the cached provider, clear stored credentials, and forget sessions.
#[no_mangle]
pub extern "C" fn bixel_ai_disconnect() {
    let mut state = AI_STATE.lock().unwrap();
    if let Some(agent) = state.agent.take() {
        let _ = agent.disconnect();
    }
    state.last_error = None;
}

/// Masked connection status + per-role model readiness. Free with
/// [`bixel_string_free`]. Never contains a full credential.
#[no_mangle]
pub extern "C" fn bixel_ai_connection_status() -> *mut c_char {
    out_cstr(connection_status_json().to_string())
}

/// Run the ChatGPT (Codex) browser sign-in (OAuth PKCE) ahead of `connect`.
/// Returns null on success or an owned error string.
#[no_mangle]
pub extern "C" fn bixel_ai_start_codex_oauth() -> *mut c_char {
    let result = (|| {
        let agent = ai_agent().or_else(|_| {
            let mut state = AI_STATE.lock().unwrap();
            let agent = std::sync::Arc::new(
                GooseAgent::new().map_err(|e| e.to_string())?,
            );
            state.agent = Some(agent.clone());
            Ok::<_, String>(agent)
        })?;
        bixel_ai::connection::start_codex_oauth(agent.runtime()).map_err(|e| e.to_string())
    })();
    match result {
        Ok(()) => std::ptr::null_mut(),
        Err(e) => out_cstr(e),
    }
}

/// Abort an in-flight ChatGPT sign-in so it can be retried immediately
/// (goose otherwise holds its OAuth lock for the full callback timeout).
#[no_mangle]
pub extern "C" fn bixel_ai_cancel_codex_oauth() {
    bixel_ai::connection::cancel_codex_oauth();
}

/// JSON object of selectable provider-scoped model options for `openrouter` or
/// `chatgpt_codex`: `{"models": ["id", ...], "default": "id",
/// "model_options": [{"id", "label", "capabilities"}]}`. OpenRouter
/// requires a stored key. Free with [`bixel_string_free`].
#[no_mangle]
pub extern "C" fn bixel_ai_list_models(provider: *const c_char) -> *mut c_char {
    let provider = match arg_str(provider).as_str() {
        "chatgpt_codex" => bixel_ai::ProviderChoice::ChatgptCodex,
        _ => bixel_ai::ProviderChoice::OpenRouter,
    };
    match bixel_ai::connection::list_models(provider) {
        Ok(catalog) => {
            let model_ids: Vec<&str> = catalog.models.iter().map(|model| model.id.as_str()).collect();
            out_cstr(
                serde_json::json!({
                    // Keep the original Goose/FFI shape for existing clients.
                    "models": model_ids,
                    "default": catalog.default,
                    // New clients use provider-scoped labels and capabilities.
                    "model_options": catalog.models,
                })
                .to_string(),
            )
        }
        Err(e) => out_cstr(
            serde_json::json!({ "error": e.to_string() }).to_string(),
        ),
    }
}

/// Lightweight availability check: connected through the UI. Provider
/// startup belongs on the worker thread.
#[no_mangle]
pub extern "C" fn bixel_ai_available() -> bool {
    let state = AI_STATE.lock().unwrap();
    matches!(&state.agent, Some(agent) if agent.handle().is_some())
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
    let Ok(agent) = ai_agent() else { return std::ptr::null_mut(); };
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
        ai_agent()?.chat_stream(request, emit).map_err(|e| e.to_string())
    })();
    if let Err(message) = result {
        emit(NativeEvent::Error { message });
        return false;
    }
    true
}

/// Public model labels only, from the active connection (or the `.env`
/// fallback). Credentials never cross this boundary.
#[no_mangle]
pub extern "C" fn bixel_ai_model_info() -> *mut c_char {
    let status = connection_status_json();
    out_cstr(serde_json::json!({
        "text": status["models"]["text"],
        "vision": status["models"]["vision"],
        "image": status["models"]["image"],
        "available": status["connected"].as_bool().unwrap_or(false)
            || status["env_available"].as_bool().unwrap_or(false),
    })
    .to_string())
}

/// Forget the current chat conversation so the next `bixel_ai_chat` starts
/// fresh with no prior context.
#[no_mangle]
pub extern "C" fn bixel_ai_chat_reset() {
    if let Ok(agent) = ai_agent() {
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

/// The image-role client from the active connection, if the image role is ready.
fn image_gen() -> Option<std::sync::Arc<dyn bixel_ai::image_gen::ImageGenerator>> {
    ai_agent().ok().and_then(|agent| agent.image_gen())
}

#[no_mangle]
pub unsafe extern "C" fn bixel_ai_generate_art(
    prompt: *const c_char,
    out_len: *mut u64,
) -> *mut u8 {
    let prompt = arg_str(prompt);
    let Some(gen) = image_gen() else { return std::ptr::null_mut() };
    match gen.generate_image(&prompt, None) {
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
    let Some(gen) = image_gen() else { return std::ptr::null_mut() };
    let bytes = unsafe { std::slice::from_raw_parts(png_in, in_len as usize) };
    let Ok(current) = bixel_ai::image::decode_png(bytes) else {
        return std::ptr::null_mut();
    };
    let prompt = arg_str(prompt);
    match gen.generate_image(&prompt, Some(&current)) {
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

fn skill_input_from_ffi(
    params: serde_json::Value,
    image: Option<bixel_ai::image::RgbaImage>,
) -> bixel_ai::skills::SkillInput {
    let prompt = params
        .get("prompt")
        .and_then(|value| value.as_str())
        .unwrap_or_default()
        .to_string();
    bixel_ai::skills::SkillInput {
        prompt,
        image,
        images: vec![],
        params,
    }
}

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

    let input = skill_input_from_ffi(params, image);

    // Deterministic skills need no engine; model-backed skills need the image
    // role to be ready (otherwise the run fails naming the missing role).
    let engine = if kind.is_deterministic() { None } else { image_gen() };
    let output = bixel_ai::skills::Skills::run(engine.as_deref(), kind, input);
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

// ----------------------------------------------------------------- tile map
//
// The TileMap designer (`.map` documents are Tiled 1.10 JSON). Same contract
// as `BixelDoc`: opaque `Arc<Mutex<TileMap>>`, bulk data via caller buffers,
// strings freed with `bixel_string_free`.

use bixel_core::map::{MapLayer, Property, TileMap};

// ------------------------------------------------------------- lifecycle

#[no_mangle]
pub extern "C" fn bixel_map_new(width: u32, height: u32, tile_width: u32, tile_height: u32) -> *mut BixelMap {
    let real = Arc::new(Mutex::new(TileMap::new(
        width.max(1) as usize,
        height.max(1) as usize,
        tile_width.max(1) as usize,
        tile_height.max(1) as usize,
    )));
    Box::into_raw(Box::new(real)) as *mut BixelMap
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_free(ptr: *mut BixelMap) {
    if !ptr.is_null() {
        unsafe { drop(Box::from_raw(ptr as *mut RealMap)) };
    }
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_from_json(json: *const c_char) -> *mut BixelMap {
    match TileMap::from_tiled_json(&arg_str(json)) {
        Ok(map) => Box::into_raw(Box::new(Arc::new(Mutex::new(map)))) as *mut BixelMap,
        Err(_) => std::ptr::null_mut(),
    }
}

/// Persist the map atomically under an explicit root (mirrors `bixel_doc_save`).
#[no_mangle]
pub unsafe extern "C" fn bixel_map_save(ptr: *const BixelMap, base: *const c_char, path: *const c_char) -> *mut c_char {
    if ptr.is_null() {
        return out_cstr("Missing map".into());
    }
    let snapshot = unsafe { map_ref(ptr) }.lock().unwrap().clone();
    let result = snapshot
        .to_tiled_json()
        .and_then(|text| bixel_core::storage::write(std::path::Path::new(&arg_str(base)), &arg_str(path), text.as_bytes()));
    match result {
        Ok(()) => std::ptr::null_mut(),
        Err(e) => out_cstr(e),
    }
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_to_json(ptr: *const BixelMap) -> *mut c_char {
    let text = unsafe { map_ref(ptr) }.lock().unwrap().to_tiled_json().unwrap_or_default();
    out_cstr(text)
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_cell_width(ptr: *const BixelMap) -> u32 {
    unsafe { map_ref(ptr) }.lock().unwrap().tile_width as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_cell_height(ptr: *const BixelMap) -> u32 {
    unsafe { map_ref(ptr) }.lock().unwrap().tile_height as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_cell_count_x(ptr: *const BixelMap) -> u32 {
    unsafe { map_ref(ptr) }.lock().unwrap().width as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_cell_count_y(ptr: *const BixelMap) -> u32 {
    unsafe { map_ref(ptr) }.lock().unwrap().height as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_pixel_width(ptr: *const BixelMap) -> u32 {
    unsafe { map_ref(ptr) }.lock().unwrap().pixel_width() as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_pixel_height(ptr: *const BixelMap) -> u32 {
    unsafe { map_ref(ptr) }.lock().unwrap().pixel_height() as u32
}

// ------------------------------------------------------------ tilesets

#[no_mangle]
pub unsafe extern "C" fn bixel_map_add_tileset(
    ptr: *mut BixelMap,
    name: *const c_char,
    image_rel: *const c_char,
    rgba: *const u8,
    img_w: u32,
    img_h: u32,
    tw: u32,
    th: u32,
    margin: u32,
    spacing: u32,
) -> i32 {
    let mut map = unsafe { map(ptr) }.lock().unwrap();
    let name = arg_str(name);
    let image = arg_str(image_rel);
    let index = match map.add_tileset(&name, &image, img_w, img_h, tw, th, margin, spacing) {
        Ok(i) => i,
        Err(_) => return -1,
    };
    if !rgba.is_null() {
        let len = img_w as usize * img_h as usize * 4;
        let pixels = unsafe { std::slice::from_raw_parts(rgba, len) };
        map.set_tileset_pixels(index, pixels);
    }
    index as i32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_remove_tileset(ptr: *mut BixelMap, index: u32) -> bool {
    unsafe { map(ptr) }.lock().unwrap().remove_tileset(index as usize)
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_tileset_count(ptr: *const BixelMap) -> u32 {
    unsafe { map_ref(ptr) }.lock().unwrap().tilesets.len() as u32
}

/// JSON array describing every tileset (index, first_gid, geometry, image rel).
#[no_mangle]
pub unsafe extern "C" fn bixel_map_tilesets_json(ptr: *const BixelMap) -> *mut c_char {
    let map = unsafe { map_ref(ptr) }.lock().unwrap();
    let list: Vec<serde_json::Value> = map
        .tilesets
        .iter()
        .enumerate()
        .map(|(i, ts)| {
            serde_json::json!({
                "index": i,
                "firstGid": ts.first_gid,
                "name": ts.name,
                "image": ts.image,
                "imageWidth": ts.image_width,
                "imageHeight": ts.image_height,
                "tileWidth": ts.tile_width,
                "tileHeight": ts.tile_height,
                "margin": ts.margin,
                "spacing": ts.spacing,
                "columns": ts.columns,
                "tileCount": ts.tile_count,
            })
        })
        .collect();
    out_cstr(serde_json::to_string(&list).unwrap_or_else(|_| "[]".into()))
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_set_tileset_pixels(ptr: *mut BixelMap, index: u32, rgba: *const u8, len: usize) -> bool {
    if rgba.is_null() {
        return false;
    }
    let pixels = unsafe { std::slice::from_raw_parts(rgba, len) };
    unsafe { map(ptr) }.lock().unwrap().set_tileset_pixels(index as usize, pixels)
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_tileset_pixels(ptr: *const BixelMap, index: u32, out: *mut u8, out_len: usize) -> bool {
    if out.is_null() {
        return false;
    }
    let mut buf = vec![0u8; out_len];
    let ok = unsafe { map_ref(ptr) }.lock().unwrap().tileset_pixels(index as usize, &mut buf);
    if ok {
        unsafe { std::ptr::copy_nonoverlapping(buf.as_ptr(), out, buf.len()) };
    }
    ok
}

/// `local` of -1 clears the autotile slot for `mask`.
#[no_mangle]
pub unsafe extern "C" fn bixel_map_set_autotile(ptr: *mut BixelMap, tileset: u32, mask: u8, local: i32) -> bool {
    let local = if local < 0 { None } else { Some(local as u32) };
    unsafe { map(ptr) }.lock().unwrap().set_autotile(tileset as usize, mask, local)
}

/// Fill `out` with the 16 autotile slots as `i64` local tile ids (-1 = empty).
#[no_mangle]
pub unsafe extern "C" fn bixel_map_autotile_slots(ptr: *const BixelMap, tileset: u32, out: *mut i64, out_len: usize) -> u32 {
    if out.is_null() || out_len == 0 {
        return 0;
    }
    let slots = unsafe { map_ref(ptr) }.lock().unwrap().autotile_slots(tileset as usize);
    for (i, slot) in slots.iter().enumerate().take(out_len) {
        unsafe {
            *out.add(i) = slot.map(i64::from).unwrap_or(-1);
        }
    }
    slots.len() as u32
}

/// Re-resolve a painted region's borders; returns changed cell count.
#[no_mangle]
pub unsafe extern "C" fn bixel_map_autotile(ptr: *mut BixelMap, layer: u32, tileset: u32, x: u32, y: u32, w: u32, h: u32) -> u32 {
    unsafe { map(ptr) }
        .lock()
        .unwrap()
        .autotile(layer as usize, tileset as usize, x as usize, y as usize, w as usize, h as usize) as u32
}

// ------------------------------------------------------------- layers

#[no_mangle]
pub unsafe extern "C" fn bixel_map_layer_count(ptr: *const BixelMap) -> u32 {
    unsafe { map_ref(ptr) }.lock().unwrap().layers.len() as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_add_layer(ptr: *mut BixelMap, name: *const c_char) -> u32 {
    let name = arg_str(name);
    let name = if name.is_empty() { None } else { Some(name.as_str()) };
    unsafe { map(ptr) }.lock().unwrap().add_tile_layer(name) as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_add_object_layer(ptr: *mut BixelMap, name: *const c_char) -> u32 {
    let name = arg_str(name);
    let name = if name.is_empty() { None } else { Some(name.as_str()) };
    unsafe { map(ptr) }.lock().unwrap().add_object_layer(name) as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_remove_layer(ptr: *mut BixelMap, index: u32) -> bool {
    unsafe { map(ptr) }.lock().unwrap().remove_layer(index as usize)
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_rename_layer(ptr: *mut BixelMap, index: u32, name: *const c_char) -> bool {
    let name = arg_str(name);
    unsafe { map(ptr) }.lock().unwrap().rename_layer(index as usize, &name)
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_reorder_layer(ptr: *mut BixelMap, from: u32, to: u32) -> bool {
    unsafe { map(ptr) }
        .lock()
        .unwrap()
        .reorder_layer(from as usize, to as usize)
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_set_layer_visible(ptr: *mut BixelMap, index: u32, visible: bool) {
    if let Some(layer) = unsafe { map(ptr) }.lock().unwrap().layers.get_mut(index as usize) {
        layer.set_visible(visible);
    }
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_set_layer_opacity(ptr: *mut BixelMap, index: u32, opacity: f32) {
    if let Some(layer) = unsafe { map(ptr) }.lock().unwrap().layers.get_mut(index as usize) {
        layer.set_opacity(opacity);
    }
}

/// One bulk call describing every layer for the layers panel.
#[no_mangle]
pub unsafe extern "C" fn bixel_map_layers_json(ptr: *const BixelMap) -> *mut c_char {
    let map = unsafe { map_ref(ptr) }.lock().unwrap();
    let list: Vec<serde_json::Value> = map
        .layers
        .iter()
        .enumerate()
        .map(|(index, layer)| {
            let mut base = serde_json::json!({
                "index": index,
                "id": layer.id(),
                "name": layer.name(),
                "visible": layer.visible(),
                "opacity": layer.opacity(),
                "type": if layer.is_objects() { "object" } else { "tile" },
            });
            match layer {
                MapLayer::Tile(data) => {
                    base["width"] = serde_json::json!(data.layer.width);
                    base["height"] = serde_json::json!(data.layer.height);
                }
                MapLayer::Objects(data) => {
                    base["objectCount"] = serde_json::json!(data.objects.len());
                }
            }
            base
        })
        .collect();
    out_cstr(serde_json::to_string(&list).unwrap_or_else(|_| "[]".into()))
}

// ------------------------------------------------------- editing (tiles)

#[no_mangle]
pub unsafe extern "C" fn bixel_map_set_tile(ptr: *mut BixelMap, layer: u32, x: i32, y: i32, gid: u32) -> bool {
    unsafe { map(ptr) }
        .lock()
        .unwrap()
        .set_tile(layer as usize, x as isize, y as isize, gid)
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_get_tile(ptr: *const BixelMap, layer: u32, x: i32, y: i32) -> u32 {
    unsafe { map_ref(ptr) }
        .lock()
        .unwrap()
        .get_tile(layer as usize, x as isize, y as isize)
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_stamp(
    ptr: *mut BixelMap,
    layer: u32,
    x: i32,
    y: i32,
    gids: *const u32,
    w: u32,
    h: u32,
    skip_empty: bool,
) -> u32 {
    if gids.is_null() || w == 0 || h == 0 {
        return 0;
    }
    let tiles = unsafe { std::slice::from_raw_parts(gids, w as usize * h as usize) };
    let pattern = bixel_core::tilemap::Pattern {
        w: w as usize,
        h: h as usize,
        tiles: tiles.to_vec(),
    };
    unsafe { map(ptr) }
        .lock()
        .unwrap()
        .stamp(layer as usize, x.max(0) as usize, y.max(0) as usize, &pattern, skip_empty) as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_fill(ptr: *mut BixelMap, layer: u32, x: i32, y: i32, gid: u32) -> u32 {
    unsafe { map(ptr) }
        .lock()
        .unwrap()
        .fill(layer as usize, x as isize, y as isize, gid) as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_paint_rect(
    ptr: *mut BixelMap, layer: u32, x0: i32, y0: i32, x1: i32, y1: i32, gid: u32,
) -> u32 {
    unsafe { map(ptr) }
        .lock()
        .unwrap()
        .paint_rect(layer as usize, x0 as isize, y0 as isize, x1 as isize, y1 as isize, gid) as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_paint_line(
    ptr: *mut BixelMap, layer: u32, x0: i32, y0: i32, x1: i32, y1: i32, gid: u32,
) -> u32 {
    unsafe { map(ptr) }
        .lock()
        .unwrap()
        .paint_line(layer as usize, x0 as isize, y0 as isize, x1 as isize, y1 as isize, gid) as u32
}

/// Copy a region into a caller-owned `w*h` u32 buffer; returns tiles written.
#[no_mangle]
pub unsafe extern "C" fn bixel_map_read_region(
    ptr: *const BixelMap,
    layer: u32,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    out: *mut u32,
) -> u32 {
    if out.is_null() || w == 0 || h == 0 {
        return 0;
    }
    let pattern = unsafe { map_ref(ptr) }
        .lock()
        .unwrap()
        .read_region(layer as usize, x as usize, y as usize, w as usize, h as usize);
    let count = pattern.w * pattern.h;
    if count > 0 {
        unsafe { std::ptr::copy_nonoverlapping(pattern.tiles.as_ptr(), out, count) };
    }
    count as u32
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_replace(
    ptr: *mut BixelMap, layer: u32, x: u32, y: u32, w: u32, h: u32, from: u32, to: u32,
) -> u32 {
    unsafe { map(ptr) }
        .lock()
        .unwrap()
        .replace(layer as usize, x as usize, y as usize, w as usize, h as usize, from, to) as u32
}

/// Magic-wand same-tile mask into a caller-owned `width*height` byte buffer.
#[no_mangle]
pub unsafe extern "C" fn bixel_map_wand_mask(
    ptr: *const BixelMap, layer: u32, x: i32, y: i32, out: *mut u8, out_len: usize,
) -> u32 {
    if out.is_null() {
        return 0;
    }
    let mut mask = vec![0u8; out_len];
    let count = unsafe { map_ref(ptr) }
        .lock()
        .unwrap()
        .wand_mask(layer as usize, x as isize, y as isize, &mut mask);
    if count > 0 {
        unsafe { std::ptr::copy_nonoverlapping(mask.as_ptr(), out, mask.len()) };
    }
    count as u32
}

// ------------------------------------------------------- editing (objects)

#[no_mangle]
pub unsafe extern "C" fn bixel_map_add_object(
    ptr: *mut BixelMap, layer: u32, name: *const c_char, kind: *const c_char,
    x: f64, y: f64, w: f64, h: f64,
) -> i64 {
    let name = arg_str(name);
    let kind = arg_str(kind);
    unsafe { map(ptr) }
        .lock()
        .unwrap()
        .add_object(layer as usize, &name, &kind, x, y, w, h)
        .map(i64::from)
        .unwrap_or(-1)
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_remove_object(ptr: *mut BixelMap, layer: u32, object_id: u32) -> bool {
    unsafe { map(ptr) }
        .lock()
        .unwrap()
        .remove_object(layer as usize, object_id)
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_set_object(
    ptr: *mut BixelMap, layer: u32, object_id: u32, name: *const c_char, kind: *const c_char,
    x: f64, y: f64, w: f64, h: f64,
) -> bool {
    let name = arg_str(name);
    let kind = arg_str(kind);
    unsafe { map(ptr) }
        .lock()
        .unwrap()
        .set_object(layer as usize, object_id, &name, &kind, x, y, w, h)
}

/// JSON array of an object layer's objects.
#[no_mangle]
pub unsafe extern "C" fn bixel_map_objects_json(ptr: *const BixelMap, layer: u32) -> *mut c_char {
    let map = unsafe { map_ref(ptr) }.lock().unwrap();
    let list: Vec<serde_json::Value> = map
        .object_layer(layer as usize)
        .map(|l| {
            l.objects
                .iter()
                .map(|o| {
                    serde_json::json!({
                        "id": o.id,
                        "name": o.name,
                        "type": o.kind,
                        "x": o.x,
                        "y": o.y,
                        "width": o.width,
                        "height": o.height,
                        "visible": o.visible,
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    out_cstr(serde_json::to_string(&list).unwrap_or_else(|_| "[]".into()))
}

// ------------------------------------------------------------ properties

fn props_json(props: &[Property]) -> serde_json::Value {
    serde_json::Value::Array(
        props
            .iter()
            .map(|p| {
                serde_json::json!({
                    "name": p.name,
                    "type": if p.kind.is_empty() { "string".to_string() } else { p.kind.clone() },
                    "value": p.value.clone(),
                })
            })
            .collect(),
    )
}

fn props_from_value(value: Option<&serde_json::Value>) -> Vec<Property> {
    let mut out = Vec::new();
    if let Some(arr) = value.and_then(serde_json::Value::as_array) {
        for p in arr {
            let name = p.get("name").and_then(serde_json::Value::as_str).unwrap_or("").to_string();
            if name.is_empty() {
                continue;
            }
            let kind = p.get("type").and_then(serde_json::Value::as_str).unwrap_or("string").to_string();
            let value = p.get("value").cloned().unwrap_or(serde_json::Value::Null);
            out.push(Property { name, kind, value });
        }
    }
    out
}

/// target: 0 = map, 1 = layer, 2 = object. `layer`/`object_id` ignored when unused.
#[no_mangle]
pub unsafe extern "C" fn bixel_map_set_properties(
    ptr: *mut BixelMap,
    target: u8,
    layer: i32,
    object_id: i64,
    props: *const c_char,
) -> bool {
    let value: serde_json::Value = match serde_json::from_str(&arg_str(props)) {
        Ok(v) => v,
        Err(_) => return false,
    };
    let props = props_from_value(Some(&value));
    let layer = if layer >= 0 { Some(layer as usize) } else { None };
    let object_id = if object_id >= 0 { Some(object_id as u32) } else { None };
    unsafe { map(ptr) }
        .lock()
        .unwrap()
        .set_properties(target, layer, object_id, props)
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_properties_json(ptr: *const BixelMap, target: u8, layer: i32, object_id: i64) -> *mut c_char {
    let map = unsafe { map_ref(ptr) }.lock().unwrap();
    let props: Vec<Property> = match target {
        0 => map.map_properties().to_vec(),
        1 if layer >= 0 => map.layer_properties(layer as usize).unwrap_or(&[]).to_vec(),
        2 if layer >= 0 && object_id >= 0 => {
            map.object_properties(layer as usize, object_id as u32).unwrap_or(&[]).to_vec()
        }
        _ => Vec::new(),
    };
    out_cstr(serde_json::to_string(&props_json(&props)).unwrap_or_else(|_| "[]".into()))
}

// -------------------------------------------------------------- resize

#[no_mangle]
pub unsafe extern "C" fn bixel_map_resize(ptr: *mut BixelMap, width: u32, height: u32) {
    unsafe { map(ptr) }
        .lock()
        .unwrap()
        .resize(width.max(1) as usize, height.max(1) as usize);
}

// ------------------------------------------------------------- history

#[no_mangle]
pub unsafe extern "C" fn bixel_map_snapshot(ptr: *mut BixelMap) {
    unsafe { map(ptr) }.lock().unwrap().snapshot();
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_undo(ptr: *mut BixelMap) -> bool {
    unsafe { map(ptr) }.lock().unwrap().undo()
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_redo(ptr: *mut BixelMap) -> bool {
    unsafe { map(ptr) }.lock().unwrap().redo()
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_can_undo(ptr: *const BixelMap) -> bool {
    unsafe { map_ref(ptr) }.lock().unwrap().can_undo()
}

#[no_mangle]
pub unsafe extern "C" fn bixel_map_can_redo(ptr: *const BixelMap) -> bool {
    unsafe { map_ref(ptr) }.lock().unwrap().can_redo()
}

// ------------------------------------------------------- render / export

/// Composite the visible tile layers into a caller-owned RGBA buffer of
/// `pixel_width * pixel_height * 4` bytes.
#[no_mangle]
pub unsafe extern "C" fn bixel_map_composite(ptr: *const BixelMap, out: *mut u8, out_len: usize) -> bool {
    if out.is_null() {
        return false;
    }
    let map = unsafe { map_ref(ptr) }.lock().unwrap();
    let buf = map.composite();
    if buf.len() > out_len || buf.is_empty() {
        return false;
    }
    unsafe { std::ptr::copy_nonoverlapping(buf.as_ptr(), out, buf.len()) };
    true
}

/// A tile layer's GIDs as a CSV string (free with `bixel_string_free`).
#[no_mangle]
pub unsafe extern "C" fn bixel_map_layer_csv(ptr: *const BixelMap, layer: u32) -> *mut c_char {
    let csv = unsafe { map_ref(ptr) }.lock().unwrap().layer_to_csv(layer as usize);
    out_cstr(csv)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn skill_runner_keeps_prompt_in_skill_input() {
        let input = skill_input_from_ffi(
            serde_json::json!({"prompt": "a fox under moonlight", "transparent": false}),
            None,
        );
        assert_eq!(input.prompt, "a fox under moonlight");
        assert_eq!(input.params["transparent"], false);
    }

    /// The status JSON must expose model roles and per-role readiness shapes
    /// and must never contain a full API key.
    #[test]
    fn connection_status_json_never_returns_secrets() {
        let value = connection_status_json();
        let text = value.to_string();
        assert!(!text.contains("sk-or-"), "status leaked an API key: {text}");
        assert!(value["key"].is_null());
        assert_eq!(value["provider"], "openrouter");
        for role in ["text", "vision", "image"] {
            assert!(value["models"][role].is_string(), "missing model role {role}");
            assert!(value["readiness"][role].is_null(), "unexpected readiness while offline");
        }
        assert_eq!(value["connected"], false);
        assert!(value["image_source"].is_null());
    }

    /// Masking must show only the last 4 characters of a key.
    #[test]
    fn masked_key_shows_last4_only() {
        let cfg = ConnectionConfig {
            provider: bixel_ai::ProviderChoice::OpenRouter,
            api_key: Some("sk-or-testsecret9876".into()),
            ..Default::default()
        };
        assert_eq!(cfg.masked_key().as_deref(), Some("…9876"));
        let json = connection_status_json().to_string();
        assert!(!json.contains("sk-or-testsecret9876"));
    }

    #[test]
    fn connection_status_masks_codex_image_key_as_absent() {
        // Codex OAuth has no primary key to mask; the secondary image key is
        // write-only and must not appear either.
        let mut cfg = ConnectionConfig {
            provider: bixel_ai::ProviderChoice::ChatgptCodex,
            api_key: None,
            image_api_key: Some("sk-or-secondary4321".into()),
            ..Default::default()
        };
        let json = serde_json::to_string(&cfg).unwrap();
        assert!(json.contains("sk-or-secondary4321"), "config round-trips locally");
        cfg.validate = false;
        assert!(cfg.masked_key().is_none());
    }
}
