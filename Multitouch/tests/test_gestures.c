// Owned gesture/palm policy, no HID opens, OS events or test doubles.
#include "../BTGestures.h"
#include <math.h>
#include <stdio.h>
static int checks,failures;
#define CHECK(x) do{checks++;if(!(x)){failures++;fprintf(stderr,"line%d: FAIL %s\n",__LINE__,#x);}}while(0)
#define NEAR(a,b) CHECK(fabs((a)-(b))<1e-8)
static const BTDisplayBounds bounds={-1920,-124,1920,1080};
static BTTouchFrame one(uint16_t x,uint16_t y){return (BTTouchFrame){.count=1,.contacts={{7,x,y}}};}
static BTTouchFrame two(uint16_t x1,uint16_t x2){return (BTTouchFrame){.count=2,.contacts={{7,x1,4000},{3,x2,4000}}};}
static BTGestureState ready(void){BTGestureState s;BTGestureBatch b;CHECK(BTGestureInit(&s,BTGestureDefaultConfig()));CHECK(BTGestureHandlePen(&s,(BTGesturePenInput){BTPenOutOfRange,0},&b));return s;}
static BTGestureBatch touch(BTGestureState *s,BTTouchFrame f,double t){BTGestureBatch b;CHECK(BTGestureHandleTouch(s,(BTGestureTouchInput){f,bounds,t},&b));CHECK(b.count<=BT_GESTURE_BATCH_CAPACITY);return b;}
static BTGestureBatch pen(BTGestureState *s,BTPenPresence p,double t){BTGestureBatch b;CHECK(BTGestureHandlePen(s,(BTGesturePenInput){p,t},&b));return b;}
static void noDown(BTGestureBatch b){for(size_t i=0;i<b.count;i++)CHECK(b.events[i].kind!=BTGesturePointerDown);}
int main(void){
    BTGestureState s=ready();BTGestureBatch b=touch(&s,one(4000,4000),0);CHECK(b.count==0);
    b=touch(&s,(BTTouchFrame){0},0.03);CHECK(b.count==2);CHECK(b.events[0].kind==BTGesturePointerDown);CHECK(b.events[1].kind==BTGesturePointerUp);CHECK(s.mode==BTGestureIdle);
    CHECK(b.events[0].x<0);CHECK(b.events[0].y>=-124 && b.events[0].y<956);
    s=ready();(void)touch(&s,one(4000,4000),0);b=touch(&s,one(4500,4000),0.02);
    CHECK(b.count==2);CHECK(b.events[0].kind==BTGesturePointerDown);CHECK(b.events[1].kind==BTGesturePointerDrag);CHECK(s.mode==BTGestureDragging);
    b=touch(&s,(BTTouchFrame){0},0.04);CHECK(b.count==1);CHECK(b.events[0].kind==BTGesturePointerUp);
    s=ready();(void)touch(&s,one(4000,4000),0);CHECK(BTGestureTick(&s,0.06,&b));CHECK(b.count==1);CHECK(b.events[0].kind==BTGesturePointerDown);BTGestureCancel(&s,&b);CHECK(b.count==1);CHECK(b.events[0].kind==BTGesturePointerUp);CHECK(b.events[0].phase==BTGesturePhaseCancelled);

    // Two-finger arrival must not click; scrolling routes at initial centroid.
    s=ready();(void)touch(&s,one(4000,4000),0);b=touch(&s,two(4000,8000),0.02);CHECK(b.count==0);
    b=touch(&s,two(4500,8500),0.04);CHECK(b.count==3);noDown(b);
    CHECK(b.events[0].kind==BTGesturePointerMove);CHECK(b.events[1].kind==BTGestureScroll);CHECK(b.events[1].phase==BTGesturePhaseBegan);CHECK(b.events[2].phase==BTGesturePhaseChanged);
    NEAR(b.events[2].deltaX,500.0/16384*1919);NEAR(b.events[2].deltaY,0);CHECK(s.mode==BTGestureScrolling);
    BTTouchFrame reordered={.count=2,.contacts={{3,9000,4000},{7,5000,4000}}};b=touch(&s,reordered,0.06);CHECK(b.count==1);CHECK(b.events[0].kind==BTGestureScroll);NEAR(b.events[0].deltaX,500.0/16384*1919);
    b=touch(&s,one(5000,4000),0.08);CHECK(b.count==1);CHECK(b.events[0].phase==BTGesturePhaseEnded);noDown(b);
    b=touch(&s,one(5200,4000),0.10);CHECK(b.count==0);(void)touch(&s,(BTTouchFrame){0},0.12);
    (void)touch(&s,one(5000,4000),0.14);b=touch(&s,(BTTouchFrame){0},0.16);CHECK(b.count==2);

    // Center fixed, span x1.5 => native incremental magnification +0.5.
    s=ready();(void)touch(&s,two(4000,8000),0);b=touch(&s,two(3000,9000),0.02);
    CHECK(b.count==3);noDown(b);CHECK(b.events[1].kind==BTGestureMagnify);CHECK(b.events[1].phase==BTGesturePhaseBegan);CHECK(b.events[2].phase==BTGesturePhaseChanged);NEAR(b.events[2].magnification,0.5);CHECK(s.mode==BTGestureMagnifying);
    b=touch(&s,two(3500,8500),0.04);CHECK(b.count==1);NEAR(b.events[0].magnification,5000.0/6000-1);
    b=touch(&s,(BTTouchFrame){0},0.06);CHECK(b.count==1);CHECK(b.events[0].phase==BTGesturePhaseEnded);
    s=ready();(void)touch(&s,two(6000,6100),0);b=touch(&s,two(6000,6100),0.2);CHECK(b.count==0);noDown(b);

    // Pen arrival cancels the active interaction, does not disable the pen.
    s=ready();(void)touch(&s,one(4000,4000),0);(void)touch(&s,one(4500,4000),0.02);
    b=pen(&s,BTPenInRange,0.03);CHECK(b.count==1);CHECK(b.events[0].kind==BTGesturePointerUp);CHECK(b.events[0].phase==BTGesturePhaseCancelled);
    b=touch(&s,one(4500,4000),5);CHECK(b.count==0);CHECK(s.mode==BTGestureBlocked);
    (void)pen(&s,BTPenOutOfRange,10);b=touch(&s,one(4500,4000),11.99);CHECK(b.count==0);
    b=touch(&s,one(4500,4000),12);CHECK(b.count==0); // Existing palm must lift.
    (void)touch(&s,(BTTouchFrame){0},12.01);(void)touch(&s,one(4500,4000),12.02);b=touch(&s,(BTTouchFrame){0},12.04);CHECK(b.count==2);
    s=ready();(void)pen(&s,BTPenInRange,1);(void)pen(&s,BTPenOutOfRange,10);(void)pen(&s,BTPenOutOfRange,11.9);
    (void)touch(&s,one(4000,4000),12);CHECK(BTGestureTick(&s,12.06,&b));CHECK(b.count==1);CHECK(b.events[0].kind==BTGesturePointerDown);BTGestureCancel(&s,&b);

    // Both multi-finger output types terminate on pen arrival/unknown state.
    s=ready();(void)touch(&s,two(4000,8000),0);(void)touch(&s,two(4500,8500),0.02);b=pen(&s,BTPenInRange,0.03);CHECK(b.count==1);CHECK(b.events[0].kind==BTGestureScroll);CHECK(b.events[0].phase==BTGesturePhaseCancelled);
    s=ready();(void)touch(&s,two(4000,8000),0);(void)touch(&s,two(3000,9000),0.02);b=pen(&s,BTPenUnknown,0.03);CHECK(b.count==1);CHECK(b.events[0].kind==BTGestureMagnify);CHECK(b.events[0].phase==BTGesturePhaseCancelled);
    CHECK(BTGestureInit(&s,BTGestureDefaultConfig()));b=touch(&s,one(4000,4000),0);CHECK(b.count==0);CHECK(s.mode==BTGestureBlocked);

    // Delay is configurable and anchored to pen exit, not repeated samples.
    s=ready();(void)pen(&s,BTPenInRange,1);(void)pen(&s,BTPenOutOfRange,10);
    CHECK(BTGestureSetResumeDelay(&s,(BTGestureDelayInput){0.5,10.1},&b));(void)touch(&s,one(4000,4000),10.5);b=touch(&s,(BTTouchFrame){0},10.52);CHECK(b.count==2);
    CHECK(!BTGestureSetResumeDelay(&s,(BTGestureDelayInput){NAN,11},&b));NEAR(s.config.resumeDelay,0.5);
    CHECK(!BTGestureSetResumeDelay(&s,(BTGestureDelayInput){-1,11},&b));CHECK(!BTGestureSetResumeDelay(&s,(BTGestureDelayInput){31,11},&b));

    // Identity and malformed/time errors must release, never leave a drag held.
    s=ready();(void)touch(&s,one(4000,4000),0);(void)touch(&s,one(4500,4000),0.02);
    BTTouchFrame different=one(4600,4000);different.contacts[0].identifier=9;b=touch(&s,different,0.03);CHECK(b.count==1);CHECK(b.events[0].kind==BTGesturePointerUp);CHECK(s.mode==BTGestureBlocked);
    s=ready();(void)touch(&s,one(4000,4000),0);(void)touch(&s,one(4500,4000),0.02);
    CHECK(!BTGestureTick(&s,0.01,&b));CHECK(b.count==1);CHECK(b.events[0].kind==BTGesturePointerUp);
    s=ready();(void)touch(&s,one(4000,4000),0);(void)touch(&s,one(4500,4000),0.02);
    BTTouchFrame bad={.count=11};CHECK(!BTGestureHandleTouch(&s,(BTGestureTouchInput){bad,bounds,0.03},&b));CHECK(b.count==1);CHECK(b.events[0].kind==BTGesturePointerUp);
    s=ready();BTTouchFrame duplicate=two(4000,8000);duplicate.contacts[1].identifier=7;CHECK(!BTGestureHandleTouch(&s,(BTGestureTouchInput){duplicate,bounds,0},&b));
    BTGestureConfig invalid=BTGestureDefaultConfig();invalid.resumeDelay=NAN;CHECK(!BTGestureInit(&s,invalid));
    // More than two contacts and identity changes cancel, not reinterpret.
    s=ready();(void)touch(&s,two(4000,8000),0);(void)touch(&s,two(4500,8500),0.02);
    BTTouchFrame palm={.count=3,.contacts={{7,4500,4000},{3,8500,4000},{9,9000,4500}}};
    b=touch(&s,palm,0.03);CHECK(b.count==1);CHECK(b.events[0].phase==BTGesturePhaseCancelled);CHECK(s.mode==BTGestureBlocked);
    b=touch(&s,one(4500,4000),0.04);CHECK(b.count==0);(void)touch(&s,(BTTouchFrame){0},0.05);
    s=ready();(void)touch(&s,two(4000,8000),0);(void)touch(&s,two(4500,8500),0.02);
    BTTouchFrame changedPair=two(4600,8600);changedPair.contacts[0].identifier=8;
    b=touch(&s,changedPair,0.03);CHECK(b.count==1);CHECK(b.events[0].phase==BTGesturePhaseCancelled);CHECK(s.mode==BTGestureBlocked);
    s=ready();(void)touch(&s,two(7000,7200),0);b=touch(&s,two(1000,13000),0.02);CHECK(b.count==3);NEAR(b.events[2].magnification,0.5);

    // Changing delay during cooldown uses the original exit time; zero works.
    s=ready();(void)pen(&s,BTPenInRange,1);(void)pen(&s,BTPenOutOfRange,10);
    (void)touch(&s,one(4000,4000),12.1);(void)touch(&s,one(4500,4000),12.12);
    CHECK(BTGestureSetResumeDelay(&s,(BTGestureDelayInput){5,12.13},&b));CHECK(b.count==1);CHECK(b.events[0].kind==BTGesturePointerUp);
    (void)touch(&s,(BTTouchFrame){0},12.2);(void)touch(&s,one(4000,4000),15);b=touch(&s,(BTTouchFrame){0},15.03);CHECK(b.count==2);
    s=ready();CHECK(BTGestureSetResumeDelay(&s,(BTGestureDelayInput){0,0},&b));(void)pen(&s,BTPenInRange,1);(void)pen(&s,BTPenOutOfRange,2);
    (void)touch(&s,one(4000,4000),2);b=touch(&s,(BTTouchFrame){0},2.03);CHECK(b.count==2);
    s=ready();(void)touch(&s,one(4000,4000),0);(void)touch(&s,one(4500,4000),0.02);
    CHECK(!BTGestureTick(&s,NAN,&b));CHECK(b.count==1);CHECK(b.events[0].kind==BTGesturePointerUp);
    s=ready();(void)touch(&s,one(4000,4000),0);(void)touch(&s,one(4500,4000),0.02);
    CHECK(!BTGestureHandleTouch(&s,(BTGestureTouchInput){one(4500,4000),(BTDisplayBounds){0},0.03},&b));CHECK(b.count==1);CHECK(b.events[0].kind==BTGesturePointerUp);
    BTGestureCancel(&s,&b);CHECK(b.count==0);
    printf("Gesture/palm policy: %d checks, %d failures\n",checks,failures);return failures?1:0;
}
