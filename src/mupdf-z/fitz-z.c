#include "fitz-z.h"

int fz_register_document_handlers_z(fz_context *ctx) {
  fz_try(ctx) { fz_register_document_handlers(ctx); }
  fz_catch(ctx) { return 0; }
  return 1;
}

fz_document *fz_open_document_z(fz_context *ctx, const char *filename) {
  fz_document *doc = NULL;
  fz_var(doc);
  fz_try(ctx) { doc = fz_open_document(ctx, filename); }
  fz_catch(ctx) { return NULL; }
  return doc;
}

int fz_count_pages_z(fz_context *ctx, fz_document *doc) {
  int count = 0;
  fz_var(count);
  fz_try(ctx) { count = fz_count_pages(ctx, doc); }
  fz_catch(ctx) { return 0; }
  return count;
}

fz_page *fz_load_page_z(fz_context *ctx, fz_document *doc, int page_number) {
  fz_page *page = NULL;
  fz_var(page);
  fz_try(ctx) { page = fz_load_page(ctx, doc, page_number); }
  fz_catch(ctx) { return NULL; }
  return page;
}

int fz_bound_page_z(fz_context *ctx, fz_page *page, fz_rect *bounds) {
  fz_try(ctx) { *bounds = fz_bound_page(ctx, page); }
  fz_catch(ctx) { return 0; }
  return 1;
}

/* Bounding boxes of the pictures on a page, for recoloring around them. */
int fz_page_image_rects_z(fz_context *ctx, fz_page *page, fz_rect *rects, int max) {
  int n = 0;
  fz_stext_page *text = NULL;
  fz_var(n);
  fz_var(text);
  fz_try(ctx) {
    fz_stext_options options = {0};
    options.flags = FZ_STEXT_PRESERVE_IMAGES;
    text = fz_new_stext_page_from_page(ctx, page, &options);
    for (fz_stext_block *block = text->first_block; block && n < max; block = block->next)
      if (block->type == FZ_STEXT_BLOCK_IMAGE)
        rects[n++] = block->bbox;
  }
  fz_always(ctx) { fz_drop_stext_page(ctx, text); }
  fz_catch(ctx) { n = 0; }
  return n;
}

/* Up to max case-insensitive hits of needle on the page. */
int fz_search_text_z(fz_context *ctx, void *text, const char *needle, fz_quad *hits, int max) {
  int n = 0;
  fz_var(n);
  fz_try(ctx) { n = fz_search_stext_page(ctx, text, needle, NULL, hits, max); }
  fz_catch(ctx) { n = 0; }
  return n;
}

fz_outline *fz_load_outline_z(fz_context *ctx, fz_document *doc) {
  fz_outline *outline = NULL;
  fz_var(outline);
  fz_try(ctx) { outline = fz_load_outline(ctx, doc); }
  fz_catch(ctx) { outline = NULL; }
  return outline;
}

/* The 0-based page an outline entry points to, or -1. */
int fz_outline_page_z(fz_context *ctx, fz_document *doc, fz_outline *outline) {
  int page = -1;
  fz_var(page);
  if (outline->page.page < 0) return -1;
  fz_try(ctx) { page = fz_page_number_from_location(ctx, doc, outline->page); }
  fz_catch(ctx) { page = -1; }
  return page;
}

fz_link *fz_load_links_z(fz_context *ctx, fz_page *page) {
  fz_link *links = NULL;
  fz_var(links);
  fz_try(ctx) { links = fz_load_links(ctx, page); }
  fz_catch(ctx) { links = NULL; }
  return links;
}

void *fz_load_text_z(fz_context *ctx, fz_page *page, int search) {
  fz_stext_page *text = NULL;
  fz_var(text);
  fz_stext_options opts = { .flags = FZ_STEXT_DEHYPHENATE };
  fz_try(ctx) { text = fz_new_stext_page_from_page(ctx, page, search ? &opts : NULL); }
  fz_catch(ctx) { text = NULL; }
  return text;
}

void fz_drop_text_z(fz_context *ctx, void *text) {
  fz_drop_stext_page(ctx, text);
}

int fz_highlight_selection_z(fz_context *ctx, void *text, fz_point a, fz_point b, fz_quad *quads, int max) {
  int count = 0;
  fz_var(count);
  fz_try(ctx) { count = fz_highlight_selection(ctx, text, a, b, quads, max); }
  fz_catch(ctx) { return 0; }
  return count;
}

void fz_snap_word_z(fz_context *ctx, void *text, fz_point *a, fz_point *b) {
  fz_point start = *a, end = *b;
  fz_var(start);
  fz_var(end);
  fz_try(ctx) { fz_snap_selection(ctx, text, &start, &end, FZ_SELECT_WORDS); }
  fz_catch(ctx) { return; }
  *a = start;
  *b = end;
}

char *fz_copy_selection_z(fz_context *ctx, void *text, fz_point a, fz_point b) {
  char *copy = NULL;
  fz_var(copy);
  fz_try(ctx) { copy = fz_copy_selection(ctx, text, a, b, 0); }
  fz_catch(ctx) { copy = NULL; }
  return copy;
}

int fz_text_at_z(void *page_text, fz_point point, fz_quad *quad) {
  fz_stext_page *text = page_text;
  for (fz_stext_block *block = text->first_block; block; block = block->next) {
    if (block->type != FZ_STEXT_BLOCK_TEXT || !fz_is_point_inside_rect(point, block->bbox)) continue;
    for (fz_stext_line *line = block->u.t.first_line; line; line = line->next) {
      if (!fz_is_point_inside_rect(point, line->bbox)) continue;
      for (fz_stext_char *ch = line->first_char; ch; ch = ch->next) {
        /* Ignore synthesized spaces and blank areas between words. */
        if (ch->c > ' ' && ch->c != 0xa0 && fz_is_point_inside_quad(point, ch->quad)) {
          *quad = ch->quad;
          return 1;
        }
      }
    }
  }
  return 0;
}

/* The 0-based page an internal link goes to, with its point in *xp, *yp,
   or -1. */
int fz_resolve_link_page_z(fz_context *ctx, fz_document *doc, const char *uri, float *xp, float *yp) {
  int page = -1;
  fz_var(page);
  fz_try(ctx) {
    fz_location loc = fz_resolve_link(ctx, doc, uri, xp, yp);
    page = fz_page_number_from_location(ctx, doc, loc);
  }
  fz_catch(ctx) { page = -1; }
  return page;
}

/* The bounding box of everything drawn on the page; empty if nothing is. */
fz_rect fz_page_marks_z(fz_context *ctx, fz_page *page) {
  fz_rect marks = fz_empty_rect;
  fz_device *dev = NULL;
  fz_var(dev);
  fz_try(ctx) {
    dev = fz_new_bbox_device(ctx, &marks);
    fz_run_page(ctx, page, dev, fz_identity, NULL);
    fz_close_device(ctx, dev);
  }
  fz_always(ctx) { fz_drop_device(ctx, dev); }
  fz_catch(ctx) { marks = fz_empty_rect; }
  return marks;
}

/* A page's drawing commands, recorded once and replayed for each strip. */
fz_display_list *fz_new_display_list_from_page_z(fz_context *ctx, fz_page *page) {
  fz_display_list *list = NULL;
  fz_var(list);
  fz_try(ctx) { list = fz_new_display_list_from_page(ctx, page); }
  fz_catch(ctx) { list = NULL; }
  return list;
}

/* Draws the part of a display list inside scissor; 0 on failure. */
int fz_run_display_list_z(fz_context *ctx, fz_display_list *list, fz_device *dev, fz_matrix ctm, fz_rect scissor) {
  int ok = 1;
  fz_var(ok);
  fz_try(ctx) { fz_run_display_list(ctx, list, dev, ctm, scissor, NULL); }
  fz_catch(ctx) { ok = 0; }
  return ok;
}

/* Fall back to a page render if its display list could not be built. */
int fz_run_page_z(fz_context *ctx, fz_page *page, fz_device *dev, fz_matrix ctm) {
  int ok = 1;
  fz_var(ok);
  fz_try(ctx) { fz_run_page(ctx, page, dev, ctm, NULL); }
  fz_catch(ctx) { ok = 0; }
  return ok;
}

/* Return both resources only if the pixmap and its draw device are ready. */
fz_device *fz_new_tile_device_z(fz_context *ctx, fz_irect bbox, fz_pixmap **pixmap) {
  fz_pixmap *pix = NULL;
  fz_device *dev = NULL;
  fz_var(pix);
  fz_var(dev);
  fz_try(ctx) {
    pix = fz_new_pixmap_with_bbox(ctx, fz_device_rgb(ctx), bbox, NULL, 0);
    fz_clear_pixmap_with_value(ctx, pix, 0xFF);
    dev = fz_new_draw_device(ctx, fz_identity, pix);
  }
  fz_catch(ctx) {
    fz_drop_pixmap(ctx, pix);
    return NULL;
  }
  *pixmap = pix;
  return dev;
}

int fz_close_device_z(fz_context *ctx, fz_device *dev) {
  fz_try(ctx) { fz_close_device(ctx, dev); }
  fz_catch(ctx) { return 0; }
  return 1;
}

int fz_tint_pixmap_z(fz_context *ctx, fz_pixmap *pix, int black, int white) {
  fz_try(ctx) { fz_tint_pixmap(ctx, pix, black, white); }
  fz_catch(ctx) { return 0; }
  return 1;
}
