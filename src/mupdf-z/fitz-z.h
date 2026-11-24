#include "mupdf/fitz.h"

int fz_register_document_handlers_z(fz_context *ctx);
fz_document *fz_open_document_z(fz_context *ctx, const char *filename);
int fz_count_pages_z(fz_context *ctx, fz_document *doc);
fz_page *fz_load_page_z(fz_context *ctx, fz_document *doc, int page_number);
int fz_bound_page_z(fz_context *ctx, fz_page *page, fz_rect *bounds);
int fz_page_image_rects_z(fz_context *ctx, fz_page *page, fz_rect *rects, int max);
int fz_search_text_z(fz_context *ctx, void *text, const char *needle, fz_quad *hits, int max);
fz_outline *fz_load_outline_z(fz_context *ctx, fz_document *doc);
int fz_outline_page_z(fz_context *ctx, fz_document *doc, fz_outline *outline);
fz_link *fz_load_links_z(fz_context *ctx, fz_page *page);
/* Keep the structured text types on the C side of the Zig bindings. */
void *fz_load_text_z(fz_context *ctx, fz_page *page, int search);
void fz_drop_text_z(fz_context *ctx, void *text);
int fz_text_at_z(void *text, fz_point point, fz_quad *quad);
char *fz_copy_line_at_z(fz_context *ctx, void *text, fz_point point);
int fz_highlight_selection_z(fz_context *ctx, void *text, fz_point a, fz_point b, fz_quad *quads, int max);
void fz_snap_word_z(fz_context *ctx, void *text, fz_point *a, fz_point *b);
char *fz_copy_selection_z(fz_context *ctx, void *text, fz_point a, fz_point b);
int fz_resolve_link_page_z(fz_context *ctx, fz_document *doc, const char *uri, float *xp, float *yp);
fz_rect fz_page_marks_z(fz_context *ctx, fz_page *page);
fz_display_list *fz_new_display_list_from_page_z(fz_context *ctx, fz_page *page);
int fz_run_display_list_z(fz_context *ctx, fz_display_list *list, fz_device *dev, fz_matrix ctm, fz_rect scissor);
int fz_run_page_z(fz_context *ctx, fz_page *page, fz_device *dev, fz_matrix ctm);
fz_device *fz_new_tile_device_z(fz_context *ctx, fz_irect bbox, fz_pixmap **pixmap);
int fz_close_device_z(fz_context *ctx, fz_device *dev);
int fz_tint_pixmap_z(fz_context *ctx, fz_pixmap *pix, int black, int white);
