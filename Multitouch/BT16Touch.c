// Touch-controller protocol and pointer state; no pen/device APIs live here.
#include "BT16Touch.h"
#include <math.h>
#include <string.h>

bool BTMatchesTouchDevice(uint32_t vendor, uint32_t product, uint32_t page, uint32_t usage) {
    return vendor == 0x6066 && product == 0x0001 &&
           ((page == 13 && usage == 4) || (page == 1 && usage == 2));
}

bool BTParseTouchReport(const uint8_t *bytes, size_t length, BTTouchFrame *frame) {
    if (!frame) return false;
    memset(frame, 0, sizeof *frame);
    if (bytes && length == 6 && bytes[0] == 3) {
        // The vendor's single-finger format uses status bit 7, then LE16 X/Y.
        if (bytes[1] & 0x80) {
            frame->count = 1;
            frame->contacts[0] = (BTContact){0,
                (uint16_t)(bytes[2] | ((uint16_t)bytes[3] << 8)),
                (uint16_t)(bytes[4] | ((uint16_t)bytes[5] << 8))};
        }
        return true;
    }
    if (!bytes || length != BT_TOUCH_REPORT_SIZE || bytes[0] != 4 ||
        bytes[55] > BT_TOUCH_MAX_CONTACTS) return false;
    if (bytes[55] == 0) return true;
    uint64_t identifiers = 0;
    for (size_t slot = 0; slot < BT_TOUCH_MAX_CONTACTS; slot++) {
        size_t offset = 1 + slot * 5;
        if (!(bytes[offset] & 0x40)) continue;
        uint8_t identifier = bytes[offset] & 0x3f;
        uint64_t bit = UINT64_C(1) << identifier;
        if ((identifiers & bit) || frame->count >= bytes[55]) {
            memset(frame, 0, sizeof *frame);
            return false;
        }
        identifiers |= bit;
        frame->contacts[frame->count++] = (BTContact){
            identifier,
            (uint16_t)(bytes[offset + 1] | ((uint16_t)bytes[offset + 2] << 8)),
            (uint16_t)(bytes[offset + 3] | ((uint16_t)bytes[offset + 4] << 8))
        };
    }
    return true;
}

bool BTExpireTouch(BTTouchState *state, double secondsSinceReport, BTPointerEvent *event) {
    if (!state || !event) return false;
    memset(event, 0, sizeof *event);
    if (!state->down || !(secondsSinceReport >= 0.5)) return false;
    bool released = BTReleaseTouch(state, event);
    state->blockedUntilClear = true;
    return released;
}

static bool validBounds(BTDisplayBounds bounds) {
    return isfinite(bounds.x) && isfinite(bounds.y) &&
           isfinite(bounds.width) && isfinite(bounds.height) &&
           isfinite(bounds.x + bounds.width) && isfinite(bounds.y + bounds.height) &&
           bounds.width >= 1 && bounds.height >= 1;
}

bool BTMapTouchPoint(BTContact point, BTDisplayBounds bounds, double *x, double *y) {
    if (!x || !y || !validBounds(bounds)) return false;
    double rawX = point.x > BT_TOUCH_X_MAX ? BT_TOUCH_X_MAX : point.x;
    double rawY = point.y > BT_TOUCH_Y_MAX ? BT_TOUCH_Y_MAX : point.y;
    *x = bounds.x + rawX / BT_TOUCH_X_MAX * (bounds.width - 1);
    *y = bounds.y + rawY / BT_TOUCH_Y_MAX * (bounds.height - 1);
    return true;
}

bool BTReleaseTouch(BTTouchState *state, BTPointerEvent *event) {
    if (!state || !event) return false;
    memset(event, 0, sizeof *event);
    bool wasDown = state->down;
    if (wasDown) *event = (BTPointerEvent){BTEventUp, state->x, state->y};
    state->down = false;
    state->blockedUntilClear = false;
    return wasDown;
}

bool BTUpdateTouch(BTTouchState *state, const BTTouchFrame *frame, BTDisplayBounds bounds, BTPointerEvent *event) {
    if (!state || !event) return false;
    memset(event, 0, sizeof *event);
    if (!frame || frame->count > BT_TOUCH_MAX_CONTACTS || !validBounds(bounds))
        return BTReleaseTouch(state, event);
    if (state->blockedUntilClear) {
        if (frame->count == 0) state->blockedUntilClear = false;
        return false;
    }
    const BTContact *primary = NULL;
    if (state->down) {
        for (size_t i = 0; i < frame->count; i++) {
            if (frame->contacts[i].identifier == state->identifier) {
                primary = &frame->contacts[i];
                break;
            }
        }
        if (!primary) {
            bool emitted = BTReleaseTouch(state, event);
            state->blockedUntilClear = frame->count > 0;
            return emitted;
        }
    } else if (frame->count > 0) {
        primary = &frame->contacts[0];
    }
    if (!primary) return false;
    double x, y;
    if (!BTMapTouchPoint(*primary, bounds, &x, &y)) return BTReleaseTouch(state, event);
    bool newlyDown = !state->down;
    bool changed = x != state->x || y != state->y;
    state->identifier = primary->identifier;
    state->down = true;
    state->x = x;
    state->y = y;
    if (newlyDown || changed) {
        *event = (BTPointerEvent){newlyDown ? BTEventDown : BTEventDrag, x, y};
        return true;
    }
    return false;
}
