use bixel_core::{document::AsepriteDoc, color::Rgba};

#[test]
fn placement_clips_and_is_one_undo_step() {
    let mut doc = AsepriteDoc::new(2, 2, &[]);
    let pixels = vec![1,0,0,255, 2,0,0,255, 3,0,0,255, 4,0,0,255];
    let layer = doc.place_image_data(&pixels, 2, 2, -1, 1, 0, "Placed").unwrap();
    assert_eq!((doc.width, doc.height, layer), (2,2,1));
    assert_eq!(doc.get_pixel(layer,0,0,1), Rgba {r:2,g:0,b:0,a:255});
    assert_eq!(doc.get_pixel(layer,0,1,1), Rgba::TRANSPARENT);
    assert!(doc.undo());
    assert_eq!(doc.layers.len(),1);
    assert!(!doc.can_undo());
    assert!(doc.redo());
    assert_eq!(doc.get_pixel(layer,0,0,1).r,2);
}

#[test]
fn invalid_placement_does_not_mutate_document() {
    let mut doc = AsepriteDoc::new(2,2, &[]);
    assert!(doc.place_image_data(&[],0,1,0,0,0,"Bad").is_err());
    assert!(doc.place_image_data(&[0;3],1,1,0,0,0,"Bad").is_err());
    assert!(doc.place_image_data(&[0;4],1,1,0,0,1,"Bad").is_err());
    assert!(doc.place_image_data(&[0;4],1,1,i32::MAX,i32::MIN,0,"Bad").is_err());
    assert_eq!(doc.layers.len(),1);
    assert!(!doc.can_undo());
}

#[test]
fn sheet_import_preserves_existing_pixels_and_aligns_row_major_cells() {
    let mut doc = AsepriteDoc::new(2,1, &[]);
    doc.set_pixel(0,0,0,0,Rgba{r:99,g:0,b:0,a:255});
    let pixels: Vec<u8> = (1..=8).flat_map(|r| [r,0,0,255]).collect();
    let layer = doc.import_sheet_data(&pixels,4,2,2,1,"Sheet").unwrap();
    assert_eq!((doc.width,doc.height,doc.frames.len()),(2,1,4));
    for frame in 0..4 {
        assert_eq!(doc.get_pixel(layer,frame,0,0).r, (frame*2+1) as u8);
        assert_eq!(doc.get_pixel(layer,frame,1,0).r, (frame*2+2) as u8);
    }
    assert_eq!(doc.get_pixel(0,0,0,0).r,99);
    assert!(doc.undo());
    assert_eq!((doc.frames.len(),doc.layers.len()),(1,1));
    assert!(!doc.can_undo());
}

#[test]
fn invalid_sheet_never_resizes_or_adds_history() {
    let mut doc = AsepriteDoc::new(2,1, &[]);
    assert!(doc.import_sheet_data(&[0;24],3,2,2,1,"Bad").is_err());
    assert!(doc.import_sheet_data(&[0;16],2,2,1,1,"Bad").is_err());
    assert!(doc.import_sheet_data(&[0;16],2,2,0,1,"Bad").is_err());
    assert!(doc.import_sheet_data(&[0;15],2,2,2,1,"Bad").is_err());
    assert_eq!((doc.width,doc.height,doc.frames.len(),doc.layers.len()),(2,1,1,1));
    assert!(!doc.can_undo());
}

#[test]
fn stamp_clips_replaces_transparency_and_uses_host_history() {
    let mut doc = AsepriteDoc::new(2,1,&[]);
    doc.set_pixel(0,0,0,0,Rgba{r:99,g:0,b:0,a:255});
    doc.snapshot();
    doc.stamp_image_data(&[5,0,0,255,0,0,0,0],2,1,-1,0,0,0).unwrap();
    assert_eq!(doc.get_pixel(0,0,0,0),Rgba::TRANSPARENT);
    assert_eq!(doc.layers.len(),1);
    assert!(doc.undo());
    assert_eq!(doc.get_pixel(0,0,0,0).r,99);
    assert!(!doc.can_undo());
    doc.layers[0].locked = true;
    assert!(doc.stamp_image_data(&[0;4],1,1,0,0,0,0).is_err());
}
