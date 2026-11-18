// Behavioral tests: real captured packets plus explicitly synthetic edge cases.
#include "../BT16Touch.h"
#include <math.h>
#include <stdio.h>
#include <string.h>
static int checks, failures, cases;
#define CHECK(x) do { checks++; if (!(x)) { failures++; fprintf(stderr, "%s:%d: FAIL %s\n", __func__, __LINE__, #x); } } while (0)
#define CLOSE(a,b) CHECK(fabs((a)-(b)) < 1e-8)
#define RUN(f) do { cases++; f(); } while (0)
static const BTDisplayBounds display = {1470, 0, 1920, 1080};
static void fromHex(const char *hex, uint8_t out[64]) { for (size_t i=0;i<64;i++) { unsigned v=0; sscanf(hex+2*i,"%2x",&v); out[i]=(uint8_t)v; } }
static BTTouchFrame one(uint8_t id, uint16_t x, uint16_t y) { BTTouchFrame f={0}; f.count=1; f.contacts[0]=(BTContact){id,x,y}; return f; }
static void packetContact(uint8_t p[64], size_t slot, uint8_t id, bool tip, uint16_t x, uint16_t y) {
    size_t o=1+slot*5; p[o]=(id&63)|(tip?64:0); p[o+1]=x&255; p[o+2]=x>>8; p[o+3]=y&255; p[o+4]=y>>8;
}
static void exact_device_matching(void) {
    CHECK(BTMatchesTouchDevice(0x6066,1,13,4)); CHECK(BTMatchesTouchDevice(0x6066,1,1,2));
    CHECK(!BTMatchesTouchDevice(0xed1,0x7821,13,2)); CHECK(!BTMatchesTouchDevice(0xed1,0x782c,13,2));
    CHECK(!BTMatchesTouchDevice(0x6066,2,13,4)); CHECK(!BTMatchesTouchDevice(0x6066,1,1,6)); CHECK(!BTMatchesTouchDevice(0,1,13,4));
}
static void real_finger_packet(void) {
    uint8_t p[64]; BTTouchFrame f={0};
    fromHex("04419f30fe0d00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000032b00f000101ff000000000000",p);
    CHECK(BTParseTouchReport(p,sizeof p,&f)); CHECK(f.count==1); CHECK(f.contacts[0].identifier==1);
    CHECK(f.contacts[0].x==12447); CHECK(f.contacts[0].y==3582);
}
static void real_idle_packet(void) {
    uint8_t p[64]; BTTouchFrame f={0};
    fromHex("04000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000088af0f000001ff000000000000",p);
    CHECK(BTParseTouchReport(p,sizeof p,&f)); CHECK(f.count==0);
}
static void malformed_reports(void) {
    uint8_t p[65]={4}; BTTouchFrame f={0};
    CHECK(!BTParseTouchReport(NULL,64,&f)); CHECK(!BTParseTouchReport(p,63,&f)); CHECK(!BTParseTouchReport(p,65,&f));
    p[0]=2; CHECK(!BTParseTouchReport(p,64,&f)); p[0]=4; CHECK(!BTParseTouchReport(p,64,NULL));
}
static void count_and_duplicate_validation(void) {
    uint8_t p[64]={4}; BTTouchFrame f={0}; p[55]=11; CHECK(!BTParseTouchReport(p,64,&f));
    p[55]=2; packetContact(p,0,3,true,10,20); packetContact(p,1,3,true,30,40); CHECK(!BTParseTouchReport(p,64,&f));
    packetContact(p,1,4,true,30,40); p[55]=1; CHECK(!BTParseTouchReport(p,64,&f));
}
static void all_slots_and_little_endian(void) {
    uint8_t p[64]={4}; BTTouchFrame f={0}; p[55]=1; packetContact(p,9,63,true,0x4000,0x2580);
    CHECK(BTParseTouchReport(p,64,&f)); CHECK(f.count==1); CHECK(f.contacts[0].identifier==63); CHECK(f.contacts[0].x==16384); CHECK(f.contacts[0].y==9600);
}
static void invalid_frame_clears_output(void) {
    uint8_t p[64]={2}; BTTouchFrame f=one(9,5,6); CHECK(!BTParseTouchReport(p,64,&f)); CHECK(f.count==0);
}
static void zero_count_releases_stale_contacts(void) {
    uint8_t p[64]={4}; BTTouchFrame f={0}; packetContact(p,0,3,true,10,20);
    CHECK(BTParseTouchReport(p,64,&f)); CHECK(f.count==0);
}
static void inactive_contacts_are_not_pressed(void) {
    uint8_t p[64]={4}; BTTouchFrame f={0}; p[55]=1; packetContact(p,0,3,false,10,20);
    CHECK(BTParseTouchReport(p,64,&f)); CHECK(f.count==0);
}
static void mapping_start(void) { double x=-1,y=-1; CHECK(BTMapTouchPoint((BTContact){1,0,0},display,&x,&y)); CLOSE(x,1470); CLOSE(y,0); }
static void mapping_end(void) { double x=0,y=0; CHECK(BTMapTouchPoint((BTContact){1,16384,9600},display,&x,&y)); CLOSE(x,3389); CLOSE(y,1079); }
static void mapping_center_uses_logical_quartz_bounds(void) { double x=0,y=0; CHECK(BTMapTouchPoint((BTContact){1,8192,4800},display,&x,&y)); CLOSE(x,2429.5); CLOSE(y,539.5); }
static void mapping_negative_origin(void) { double x=0,y=0; CHECK(BTMapTouchPoint((BTContact){1,0,0},(BTDisplayBounds){-1920,-1080,1920,1080},&x,&y)); CLOSE(x,-1920); CLOSE(y,-1080); }
static void mapping_clamps(void) { double x=0,y=0; CHECK(BTMapTouchPoint((BTContact){1,65535,65535},display,&x,&y)); CLOSE(x,3389); CLOSE(y,1079); }
static void invalid_display(void) { double x=0,y=0; CHECK(!BTMapTouchPoint((BTContact){0},(BTDisplayBounds){0,0,0,1080},&x,&y)); CHECK(!BTMapTouchPoint((BTContact){0},(BTDisplayBounds){NAN,0,1920,1080},&x,&y)); CHECK(!BTMapTouchPoint((BTContact){0},display,NULL,&y)); }
static void tap_down_then_up(void) {
    BTTouchState s={0}; BTPointerEvent e={0}; BTTouchFrame f=one(1,8192,4800);
    CHECK(BTUpdateTouch(&s,&f,display,&e)); CHECK(e.phase==BTEventDown); CLOSE(e.x,2429.5); CLOSE(e.y,539.5); CHECK(s.down);
    f.count=0; CHECK(BTUpdateTouch(&s,&f,display,&e)); CHECK(e.phase==BTEventUp); CHECK(!s.down); CLOSE(e.x,2429.5);
}
static void movement_and_no_duplicate_click(void) {
    BTTouchState s={0}; BTPointerEvent e={0}; BTTouchFrame f=one(1,0,0);
    (void)BTUpdateTouch(&s,&f,display,&e); CHECK(!BTUpdateTouch(&s,&f,display,&e));
    f.contacts[0].x=16384; CHECK(BTUpdateTouch(&s,&f,display,&e)); CHECK(e.phase==BTEventDrag); CLOSE(e.x,3389);
}
static void stable_primary_after_slot_reorder(void) {
    BTTouchState s={0}; BTPointerEvent e={0}; BTTouchFrame f=one(5,0,0); (void)BTUpdateTouch(&s,&f,display,&e);
    f.count=2; f.contacts[0]=(BTContact){6,0,0}; f.contacts[1]=(BTContact){5,8192,4800};
    CHECK(BTUpdateTouch(&s,&f,display,&e)); CHECK(e.phase==BTEventDrag); CLOSE(e.x,2429.5); CHECK(s.identifier==5);
}
static void primary_lift_waits_for_all_fingers(void) {
    BTTouchState s={0}; BTPointerEvent e={0}; BTTouchFrame f=one(5,0,0); (void)BTUpdateTouch(&s,&f,display,&e);
    f=one(6,8192,4800); CHECK(BTUpdateTouch(&s,&f,display,&e)); CHECK(e.phase==BTEventUp); CHECK(s.blockedUntilClear);
    CHECK(!BTUpdateTouch(&s,&f,display,&e)); f.count=0; CHECK(!BTUpdateTouch(&s,&f,display,&e));
    f=one(6,8192,4800); CHECK(BTUpdateTouch(&s,&f,display,&e)); CHECK(e.phase==BTEventDown);
}
static void cancel_releases_once(void) {
    BTTouchState s={0}; BTPointerEvent e={0}; BTTouchFrame f=one(1,0,0); (void)BTUpdateTouch(&s,&f,display,&e);
    CHECK(BTReleaseTouch(&s,&e)); CHECK(e.phase==BTEventUp); CHECK(!s.down); CHECK(!BTReleaseTouch(&s,&e));
}
static void missing_display_releases(void) {
    BTTouchState s={0}; BTPointerEvent e={0}; BTTouchFrame f=one(1,0,0); (void)BTUpdateTouch(&s,&f,display,&e);
    CHECK(BTUpdateTouch(&s,&f,(BTDisplayBounds){0},&e)); CHECK(e.phase==BTEventUp); CHECK(!s.down);
}
static void contact_zero_is_valid(void) { BTTouchState s={0}; BTPointerEvent e={0}; BTTouchFrame f=one(0,0,0); CHECK(BTUpdateTouch(&s,&f,display,&e)); CHECK(s.identifier==0); CHECK(e.phase==BTEventDown); }
static void lost_release_watchdog(void) {
    BTTouchState s={0}; BTPointerEvent e={0}; BTTouchFrame f=one(2,0,0); (void)BTUpdateTouch(&s,&f,display,&e);
    CHECK(!BTExpireTouch(&s,0.49,&e)); CHECK(s.down); CHECK(BTExpireTouch(&s,0.5,&e)); CHECK(e.phase==BTEventUp); CHECK(!s.down);
    CHECK(!BTUpdateTouch(&s,&f,display,&e)); f.count=0; (void)BTUpdateTouch(&s,&f,display,&e); f=one(2,0,0);
    CHECK(BTUpdateTouch(&s,&f,display,&e)); CHECK(e.phase==BTEventDown);
}
// Synthetic single-finger packets derived from the signed vendor driver's
// didReceiveTouchReport/handleTouchScreenInput implementation, not a live capture.
static void vendor_single_finger_down(void) {
    const uint8_t p[6]={3,0x80,0x34,0x12,0x78,0x05}; BTTouchFrame f={0};
    CHECK(BTParseTouchReport(p,sizeof p,&f)); CHECK(f.count==1);
    CHECK(f.contacts[0].identifier==0); CHECK(f.contacts[0].x==0x1234); CHECK(f.contacts[0].y==0x0578);
}
static void vendor_single_finger_release(void) {
    const uint8_t p[6]={3,0,0xff,0xff,0xff,0xff}; BTTouchFrame f=one(9,1,2);
    CHECK(BTParseTouchReport(p,sizeof p,&f)); CHECK(f.count==0);
}
static void vendor_single_finger_status_bit(void) {
    uint8_t p[6]={3,0x7f,0,0,0,0}; BTTouchFrame f={0};
    CHECK(BTParseTouchReport(p,sizeof p,&f)); CHECK(f.count==0);
    p[1]=0xff; CHECK(BTParseTouchReport(p,sizeof p,&f)); CHECK(f.count==1);
}
static void vendor_single_finger_lengths(void) {
    uint8_t p[7]={3,0x80,0,0,0,0,0}; BTTouchFrame f=one(8,1,2);
    CHECK(!BTParseTouchReport(p,5,&f)); CHECK(f.count==0);
    CHECK(!BTParseTouchReport(p,7,&f)); CHECK(f.count==0);
    CHECK(BTParseTouchReport(p,6,&f)); CHECK(f.count==1);
}
static void vendor_single_finger_down_drag_up(void) {
    uint8_t p[6]={3,0x80,0,0,0,0}; BTTouchFrame f={0}; BTTouchState s={0}; BTPointerEvent e={0};
    CHECK(BTParseTouchReport(p,sizeof p,&f)); CHECK(BTUpdateTouch(&s,&f,display,&e)); CHECK(e.phase==BTEventDown);
    p[3]=0x40; p[4]=0x80; p[5]=0x25;
    CHECK(BTParseTouchReport(p,sizeof p,&f)); CHECK(BTUpdateTouch(&s,&f,display,&e)); CHECK(e.phase==BTEventDrag);
    CLOSE(e.x,3389); CLOSE(e.y,1079);
    p[1]=0; CHECK(BTParseTouchReport(p,sizeof p,&f)); CHECK(BTUpdateTouch(&s,&f,display,&e)); CHECK(e.phase==BTEventUp); CHECK(!s.down);
}
int main(void) {
    RUN(exact_device_matching); RUN(real_finger_packet); RUN(real_idle_packet); RUN(malformed_reports); RUN(count_and_duplicate_validation);
    RUN(all_slots_and_little_endian); RUN(invalid_frame_clears_output); RUN(zero_count_releases_stale_contacts); RUN(inactive_contacts_are_not_pressed);
    RUN(mapping_start); RUN(mapping_end); RUN(mapping_center_uses_logical_quartz_bounds); RUN(mapping_negative_origin); RUN(mapping_clamps); RUN(invalid_display);
    RUN(tap_down_then_up); RUN(movement_and_no_duplicate_click); RUN(stable_primary_after_slot_reorder); RUN(primary_lift_waits_for_all_fingers);
    RUN(cancel_releases_once); RUN(missing_display_releases); RUN(contact_zero_is_valid); RUN(lost_release_watchdog);
    RUN(vendor_single_finger_down); RUN(vendor_single_finger_release); RUN(vendor_single_finger_status_bit);
    RUN(vendor_single_finger_lengths); RUN(vendor_single_finger_down_drag_up);
    printf("Touch core: %d cases, %d checks, %d failures\n",cases,checks,failures); return failures ? 1 : 0;
}
