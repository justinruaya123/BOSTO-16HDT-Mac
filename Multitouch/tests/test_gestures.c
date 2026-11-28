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
static void checkPairRecontact(void){
    // Lift from pending, scrolling, or magnifying. Only new pair motion counts.
    for(int prior=0;prior<3;prior++){
        BTGestureState s=ready(); BTGestureBatch b;
        (void)touch(&s,two(4000,8000),0);
        if(prior)(void)touch(&s,prior==1?two(4500,8500):two(3500,8500),0.02);
        b=touch(&s,one(4500,4000),0.04);
        CHECK(b.count==(prior?1u:0u));
        if(prior)CHECK(b.events[0].phase==BTGesturePhaseEnded);
        CHECK(touch(&s,one(5000,4000),0.10).count==0);
        CHECK(BTGestureTick(&s,0.20,&b) && b.count==0);
        BTTouchFrame pair=two(5000,11000);
        pair.contacts[1].identifier=12;  // A returning finger can receive a new ID.
        CHECK(touch(&s,pair,0.22).count==0);
        CHECK(touch(&s,pair,0.24).count==0);
        pair.contacts[0].x=prior==2?4700:5300; pair.contacts[1].x=11300;
        b=touch(&s,pair,0.26);
        CHECK(b.count==3);
        if(b.count==3){
            BTGestureKind kind=prior==2?BTGestureMagnify:BTGestureScroll;
            CHECK(b.events[0].kind==BTGesturePointerMove);
            CHECK(b.events[1].kind==kind && b.events[1].phase==BTGesturePhaseBegan);
            CHECK(b.events[2].kind==kind && b.events[2].phase==BTGesturePhaseChanged);
            if(prior==2){NEAR(b.events[2].magnification,0.1);}
            else {NEAR(b.events[2].deltaX,300.0/16384*1919);}
        }
    }
}
static void checkLostSurvivorStaysBlocked(void){
    for(int loss=0;loss<4;loss++){
        BTGestureState s=ready(); BTGestureBatch b;
        BTTouchFrame single=one(4000,4000), pair=two(4000,8000);
        (void)touch(&s,pair,0);
        if(loss==0)single.contacts[0].identifier=11; // Not from the original pair.
        (void)touch(&s,single,0.02);
        if(loss==1){single.contacts[0].identifier=11;(void)touch(&s,single,0.04);}
        if(loss==2)pair.contacts[0].identifier=11; // Neither ID is the survivor.
        if(loss==3)BTGestureCancelForReportGap(&s,1,&b);
        CHECK(touch(&s,pair,1.02).count==0);
        pair.contacts[0].x+=500;pair.contacts[1].x+=500;
        CHECK(touch(&s,pair,1.04).count==0);
    }
}
static BTGestureState nativeState(void){
    BTGestureState s; BTGestureConfig c=BTGestureDefaultConfig();
    c.nativeSinglePointer=true;c.allowTouchBeforePenReport=true;
    CHECK(BTGestureInit(&s,c));return s;
}
static void checkPointer(BTGestureEvent e,BTGestureKind kind,BTGesturePhase phase,double x,double y){
    CHECK(e.kind==kind && e.phase==phase);NEAR(e.x,x);NEAR(e.y,y);
}
static void checkNativeTapAndDrag(void){
    BTGestureState s=nativeState();BTGestureBatch b;
    BTTouchFrame center=one(8192,4800),corner=one(16384,9600),lift={0};
    b=touch(&s,center,0);CHECK(b.count==1);
    checkPointer(b.events[0],BTGesturePointerMove,BTGesturePhaseNone,-960.5,415.5);
    CHECK(touch(&s,one(8193,4800),0.01).count==0); // Sub-slop jitter, not a drag.
    CHECK(touch(&s,center,1).count==0);
    b=touch(&s,lift,1.01);CHECK(b.count==2);
    checkPointer(b.events[0],BTGesturePointerDown,BTGesturePhaseBegan,-960.5,415.5);
    checkPointer(b.events[1],BTGesturePointerUp,BTGesturePhaseEnded,-960.5,415.5);
    CHECK(touch(&s,lift,1.02).count==0);

    (void)touch(&s,center,2);b=touch(&s,corner,2.01);CHECK(b.count==2);
    checkPointer(b.events[0],BTGesturePointerDown,BTGesturePhaseBegan,-960.5,415.5);
    checkPointer(b.events[1],BTGesturePointerDrag,BTGesturePhaseChanged,-1,955);
    b=touch(&s,one(0,0),2.02);CHECK(b.count==1);
    checkPointer(b.events[0],BTGesturePointerDrag,BTGesturePhaseChanged,-1920,-124);
    b=touch(&s,lift,2.03);CHECK(b.count==1);
    checkPointer(b.events[0],BTGesturePointerUp,BTGesturePhaseEnded,-1920,-124);
    CHECK(touch(&s,lift,2.04).count==0);
}
static void checkNativeLatePartner(double delay){
    BTGestureState s=nativeState();BTGestureBatch b;
    (void)touch(&s,one(4000,4000),0);
    CHECK(BTGestureTick(&s,delay,&b) && b.count==0);
    CHECK(touch(&s,one(4000,4000),delay).count==0);
    CHECK(touch(&s,two(4000,8000),delay).count==0);
    CHECK(touch(&s,two(4500,8500),delay).count==0); // Pan.
    CHECK(touch(&s,one(4500,4000),delay).count==0);
    CHECK(touch(&s,one(5000,4000),delay).count==0); // No tail drag.
    CHECK(touch(&s,two(5000,8500),delay).count==0);
    CHECK(touch(&s,two(3000,10500),delay).count==0); // Returning partner, pinch.
    CHECK(touch(&s,one(3000,4000),delay).count==0);
    CHECK(touch(&s,(BTTouchFrame){0},delay).count==0); // No tail tap.
    b=touch(&s,one(0,0),delay);CHECK(b.count==1 && b.events[0].kind==BTGesturePointerMove);
    CHECK(touch(&s,(BTTouchFrame){0},delay).count==2);
}
static void checkNativeCancellation(void){
    BTTouchFrame single=one(0,0),corner=one(16384,9600),pair=two(4000,8000),palm=pair,lift={0};
    palm.count=3;palm.contacts[2]=(BTContact){9,5000,5000};
    for(int drag=0;drag<=1;drag++)for(int reason=0;reason<5;reason++){
        BTGestureState s=nativeState();BTGestureBatch b;
        (void)touch(&s,single,0);
        if(drag)(void)touch(&s,corner,0.01);
        switch(reason){
            case 0:b=touch(&s,pair,0.02);break;
            case 1:b=touch(&s,palm,0.02);break;
            case 2:BTGestureCancel(&s,&b);break; // Stop.
            case 3:BTGestureCancelForReportGap(&s,1,&b);break;
            default:b=pen(&s,BTPenInRange,0.02);break;
        }
        CHECK(b.count==(size_t)drag);
        if(drag)checkPointer(b.events[0],BTGesturePointerUp,BTGesturePhaseCancelled,-1,955);
        if(reason==4){
            CHECK(touch(&s,corner,1).count==0);
            (void)pen(&s,BTPenOutOfRange,2);
            CHECK(touch(&s,single,3.9).count==0);
        }
        CHECK(touch(&s,pair,4).count==0);
        CHECK(touch(&s,two(5000,9000),4.01).count==0);
        CHECK(touch(&s,single,4.02).count==0);
        CHECK(touch(&s,corner,4.03).count==0);
        CHECK(touch(&s,lift,4.04).count==0);
        b=touch(&s,single,4.05);CHECK(b.count==1 && b.events[0].kind==BTGesturePointerMove);
        CHECK(touch(&s,lift,4.06).count==2);
    }
}
int main(void){
    checkNativeTapAndDrag();checkNativeLatePartner(0.06);checkNativeLatePartner(30);checkNativeCancellation();
    checkPairRecontact();checkLostSurvivorStaysBlocked();
    BTGestureState probe;CHECK(BTGestureInit(&probe,BTGestureDefaultConfig()));
    CHECK(BTGestureGetReadiness(&probe,0)==BTGestureReadinessUnknown);
    (void)pen(&probe,BTPenInRange,1);
    CHECK(BTGestureGetReadiness(&probe,1)==BTGestureReadinessPen);
    (void)pen(&probe,BTPenOutOfRange,2);
    CHECK(BTGestureGetReadiness(&probe,3.999)==BTGestureReadinessPen);
    BTGestureState unchanged=probe;
    CHECK(BTGestureGetReadiness(&probe,4)==BTGestureReadinessReady);
    CHECK(probe.lastTime==unchanged.lastTime && probe.mode==unchanged.mode);
    (void)touch(&probe,one(4000,4000),3);
    CHECK(BTGestureGetReadiness(&probe,4)==BTGestureReadinessLiftRequired);
    (void)touch(&probe,(BTTouchFrame){0},4);
    CHECK(BTGestureGetReadiness(&probe,4)==BTGestureReadinessReady);
    CHECK(BTGestureGetReadiness(&probe,NAN)==BTGestureReadinessUnknown);
    CHECK(BTGestureGetReadiness(&probe,3)==BTGestureReadinessUnknown);
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

    // A thumb can stay planted. Moving only the other finger changes span
    // and center together; do not latch scroll before pinch slop is crossed.
    for(int sign=-1;sign<=1;sign+=2){
        s=ready();(void)touch(&s,two(4000,8000),0);
        b=touch(&s,two(4000,8000+80*sign),0.01);CHECK(b.count==0);
        b=touch(&s,two(4000,8000+320*sign),0.02);
        CHECK(b.count==3 && b.events[2].kind==BTGestureMagnify);
        NEAR(b.events[2].magnification,0.08*sign);
    }
    // Unequal but parallel movement with little change of span remains scroll.
    s=ready();(void)touch(&s,two(4000,8000),0);b=touch(&s,two(4250,8320),0.02);
    CHECK(b.count==3 && b.events[2].kind==BTGestureScroll);
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
