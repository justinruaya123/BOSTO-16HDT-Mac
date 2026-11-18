#ifndef BT16_TOUCH_H
#define BT16_TOUCH_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define BT_TOUCH_MAX_CONTACTS 10
#define BT_TOUCH_REPORT_SIZE 64
#define BT_TOUCH_X_MAX 16384
#define BT_TOUCH_Y_MAX 9600

typedef struct { uint8_t identifier; uint16_t x, y; } BTContact;
typedef struct { size_t count; BTContact contacts[BT_TOUCH_MAX_CONTACTS]; } BTTouchFrame;
typedef struct { double x, y, width, height; } BTDisplayBounds;
typedef enum { BTEventNone, BTEventDown, BTEventDrag, BTEventUp } BTEventPhase;
typedef struct { BTEventPhase phase; double x, y; } BTPointerEvent;
typedef struct { bool down, blockedUntilClear; uint8_t identifier; double x, y; } BTTouchState;

bool BTMatchesTouchDevice(uint32_t vendor, uint32_t product, uint32_t usagePage, uint32_t usage);
bool BTParseTouchReport(const uint8_t *bytes, size_t length, BTTouchFrame *frame);
bool BTMapTouchPoint(BTContact point, BTDisplayBounds bounds, double *x, double *y);
bool BTUpdateTouch(BTTouchState *state, const BTTouchFrame *frame, BTDisplayBounds bounds, BTPointerEvent *event);
bool BTReleaseTouch(BTTouchState *state, BTPointerEvent *event);
bool BTExpireTouch(BTTouchState *state, double secondsSinceReport, BTPointerEvent *event);
#endif
