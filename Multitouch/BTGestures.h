#ifndef BT_GESTURES_H
#define BT_GESTURES_H
#include "BT16Touch.h"
#define BT_GESTURE_BATCH_CAPACITY 4

typedef enum { BTPenUnknown, BTPenOutOfRange, BTPenInRange } BTPenPresence;
typedef enum { BTGestureIdle, BTGestureOnePending, BTGestureDragging, BTGestureTwoPending,
               BTGestureScrolling, BTGestureMagnifying, BTGestureBlocked } BTGestureMode;
typedef enum { BTGesturePointerMove, BTGesturePointerDown, BTGesturePointerDrag, BTGesturePointerUp,
               BTGestureScroll, BTGestureMagnify } BTGestureKind;
typedef enum { BTGesturePhaseNone, BTGesturePhaseBegan, BTGesturePhaseChanged,
               BTGesturePhaseEnded, BTGesturePhaseCancelled } BTGesturePhase;
typedef struct {
    BTGestureKind kind; BTGesturePhase phase;
    double x,y,deltaX,deltaY,magnification;
} BTGestureEvent;
typedef struct { size_t count; BTGestureEvent events[BT_GESTURE_BATCH_CAPACITY]; } BTGestureBatch;
typedef struct {
    double resumeDelay,armingDelay,pointerSlop,scrollSlop,pinchSlop,minSpan,maxMagnification;
} BTGestureConfig;
typedef struct { BTTouchFrame frame; BTDisplayBounds bounds; double time; } BTGestureTouchInput;
typedef struct { BTPenPresence presence; double time; } BTGesturePenInput;
typedef struct { double seconds,time; } BTGestureDelayInput;
typedef struct {
    BTGestureConfig config; BTGestureMode mode; BTPenPresence pen;
    bool clockValid,penOutSeen,penWasDetected;
    double lastTime,penOutAt,startedAt;
    size_t lastCount; uint8_t identifiers[2];
    double x,y,startX,startY,lastCx,lastCy,lastSpan,startSpan,anchorX,anchorY;
} BTGestureState;
BTGestureConfig BTGestureDefaultConfig(void);
bool BTGestureInit(BTGestureState *state,BTGestureConfig config);
/* Always consume the batch, including cancellation output on rejected input. */
bool BTGestureHandleTouch(BTGestureState *state,BTGestureTouchInput input,BTGestureBatch *batch);
bool BTGestureHandlePen(BTGestureState *state,BTGesturePenInput input,BTGestureBatch *batch);
bool BTGestureSetResumeDelay(BTGestureState *state,BTGestureDelayInput input,BTGestureBatch *batch);
bool BTGestureTick(BTGestureState *state,double time,BTGestureBatch *batch);
void BTGestureCancel(BTGestureState *state,BTGestureBatch *batch);
#endif
