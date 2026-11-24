#import "UnifiedPen.h"
#include <math.h>
#import <Foundation/Foundation.h>
#import <IOKit/hidsystem/IOLLEvent.h>
bool UPParse(const uint8_t *b,size_t n,UPPacket *p) {
    if(!b || !p || n!=8 || b[0]!=1 || (b[1]&0xe0))return false;
    UPPacket v={.x=b[2]|b[3]<<8,.y=b[4]|b[5]<<8,.pressure=b[6]|b[7]<<8,
        .tip=b[1]&1,.barrel=(b[1]&2)!=0,.secondary=(b[1]&4)!=0,.invert=(b[1]&8)!=0,.inRange=(b[1]&16)!=0};
    if(v.x>0x4600 || v.y>0x2800 || v.pressure>0x2000)return false;
    *p=v;return true;
}
void UPClear(UPBatch *b) {for(size_t i=0;i<b->count;i++)CFRelease(b->events[i]);*b=(UPBatch){0};}
static bool append(UPBatch *b,CGEventRef e) {if(!e)return false;b->events[b->count++]=e;return true;}
static CGEventRef proximity(UPPacket p,bool enter) {
    CGEventRef e=CGEventCreate(NULL);if(!e)return NULL;CGEventSetType(e,kCGEventTabletProximity);
    CGEventSetIntegerValueField(e,kCGTabletProximityEventVendorID,0x0ed1);
    CGEventSetIntegerValueField(e,kCGTabletProximityEventTabletID,0x7821);
    CGEventSetIntegerValueField(e,kCGTabletProximityEventDeviceID,1);
    CGEventSetIntegerValueField(e,kCGTabletProximityEventPointerID,1);
    CGEventSetIntegerValueField(e,kCGTabletProximityEventSystemTabletID,1);
    CGEventSetIntegerValueField(e,kCGTabletProximityEventPointerType,p.invert?3:1);
    CGEventSetIntegerValueField(e,kCGTabletProximityEventCapabilityMask,NX_TABLET_CAPABILITY_DEVICEIDMASK | NX_TABLET_CAPABILITY_ABSXMASK | NX_TABLET_CAPABILITY_ABSYMASK | NX_TABLET_CAPABILITY_BUTTONSMASK | NX_TABLET_CAPABILITY_PRESSUREMASK);
    CGEventSetIntegerValueField(e,kCGTabletProximityEventEnterProximity,enter);return e;
}
static CGEventRef point(UPPacket p,CGRect r,CGEventType type,double exponent) {
    CGPoint location=CGPointMake(r.origin.x+p.x/17920.0*r.size.width,r.origin.y+p.y/10240.0*r.size.height);
    CGEventRef e=CGEventCreateMouseEvent(NULL,type,location,kCGMouseButtonLeft);if(!e)return NULL;
    double pressure=(p.inRange && p.tip && type!=kCGEventLeftMouseUp)?UPPressure(p,exponent):0;
    CGEventSetIntegerValueField(e,kCGMouseEventSubtype,1);
    CGEventSetIntegerValueField(e,kCGMouseEventClickState,1);
    CGEventSetDoubleValueField(e,kCGMouseEventPressure,pressure);
    CGEventSetDoubleValueField(e,kCGTabletEventPointPressure,pressure);
    CGEventSetIntegerValueField(e,kCGTabletEventPointX,p.x);
    CGEventSetIntegerValueField(e,kCGTabletEventPointY,p.y);
    CGEventSetIntegerValueField(e,kCGTabletEventDeviceID,1);
    CGEventSetIntegerValueField(e,kCGTabletEventPointButtons,(type!=kCGEventLeftMouseUp && p.tip?1:0)|(p.barrel?2:0)|(p.secondary?4:0));
    return e;
}
void UPCancel(UPState *s,UPBatch *b) {
    *b=(UPBatch){0};
    if(s->down)(void)append(b,point(s->last,s->bounds,kCGEventLeftMouseUp,1));
    if(s->inRange)(void)append(b,proximity(s->last,false));
    *s=(UPState){0};
}
bool UPAdvance(UPState *s,UPPacket p,CGRect r,double exponent,UPBatch *b) {
    *b=(UPBatch){0};
    if(!isfinite(r.origin.x)||!isfinite(r.origin.y)||!isfinite(r.size.width)||!isfinite(r.size.height)||r.size.width<=0||r.size.height<=0||!isfinite(exponent)||exponent<0.25||exponent>4)return false;
    if(s->inRange && (!p.inRange || p.invert!=s->invert))UPCancel(s,b);
    if(!p.inRange)return true;
    if(!s->inRange && !append(b,proximity(p,true)))goto fail;
    CGEventType type=p.tip?(s->down?kCGEventLeftMouseDragged:kCGEventLeftMouseDown):(s->down?kCGEventLeftMouseUp:kCGEventMouseMoved);
    if(!append(b,point(p,r,type,exponent)))goto fail;
    *s=(UPState){.inRange=true,.down=p.tip,.invert=p.invert,.last=p,.bounds=r};return true;
fail:
    UPClear(b);return false;
}

double UPValidatedExponent(id value) {
    if(![value isKindOfClass:NSNumber.class])return 1;
    double exponent=[value doubleValue];
    return isfinite(exponent) && exponent>=0.25 && exponent<=4?exponent:1;
}
double UPPressure(UPPacket p,double exponent) {
    if(!p.inRange || !p.tip)return 0;
    return pow(p.pressure/8192.0,exponent);
}
uint8_t UPButtonPresses(UPButtonState *s,UPPacket p,bool capturing) {
    if(!p.inRange){*s=(UPButtonState){0};return 0;}
    uint8_t held=(p.barrel?1:0)|(p.secondary?2:0);
    uint8_t presses=s->known && s->invert==p.invert && !capturing?(held & ~s->held):0;
    *s=(UPButtonState){.known=true,.invert=p.invert,.held=held};return presses;
}
bool UPShortcutValid(uint16_t key,CGEventFlags modifiers) {
    CGEventFlags allowed=kCGEventFlagMaskCommand|kCGEventFlagMaskShift|kCGEventFlagMaskAlternate|kCGEventFlagMaskControl;
    if(modifiers & ~allowed)return false;
    // Standard ANSI/ISO/JIS printable keys, navigation, keypad and F1–F20.
    // Exclude modifier keys, Caps Lock, Fn, volume/media and undefined codes.
    switch(key) {
        case 0 ... 51: case 53: case 64: case 65: case 67: case 69: case 71: case 75: case 76:
        case 78 ... 107: case 109 ... 111: case 113:
        case 114 ... 126: return true;
        default:return false;
    }
}
bool UPShortcutEvents(uint16_t key,CGEventFlags modifiers,UPBatch *batch) {
    *batch=(UPBatch){0};if(!UPShortcutValid(key,modifiers))return false;
    CGEventRef down=CGEventCreateKeyboardEvent(NULL,key,true);
    CGEventRef up=CGEventCreateKeyboardEvent(NULL,key,false);
    if(!down || !up){if(down)CFRelease(down);if(up)CFRelease(up);return false;}
    CGEventSetFlags(down,modifiers);CGEventSetFlags(up,0);
    batch->events[0]=down;batch->events[1]=up;batch->count=2;return true;
}

NSDictionary *UPValidatedShortcut(id value) {
    if(![value isKindOfClass:NSDictionary.class])return nil;
    id key=value[@"key"],mods=value[@"modifiers"];
    if(![key isKindOfClass:NSNumber.class] || ![mods isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)key)==CFBooleanGetTypeID() ||
        CFGetTypeID((__bridge CFTypeRef)mods)==CFBooleanGetTypeID() ||
        !isfinite([key doubleValue]) || [key doubleValue]!=[key unsignedShortValue] ||
        !isfinite([mods doubleValue]) || [mods doubleValue]!=[mods unsignedLongLongValue] ||
        !UPShortcutValid([key unsignedShortValue],[mods unsignedLongLongValue]))return nil;
    NSString *name=value[@"name"];
    if(![name isKindOfClass:NSString.class] || name.length>32 || [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location!=NSNotFound)name=@"";
    return @{@"key":key,@"modifiers":mods,@"name":[name copy]};
}

static bool shortcutCapture;
void UPSetShortcutCapture(bool capturing) { shortcutCapture=capturing; }
bool UPShortcutCaptureActive(void) { return shortcutCapture; }
