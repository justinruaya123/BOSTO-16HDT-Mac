#import <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <stdint.h>
typedef struct { uint16_t x,y,pressure; bool tip,barrel,secondary,invert,inRange; } UPPacket;
typedef struct { bool inRange,down,invert; UPPacket last; CGRect bounds; } UPState;
typedef struct { size_t count; CGEventRef events[4]; } UPBatch;
bool UPParse(const uint8_t *bytes,size_t length,UPPacket *packet);
bool UPAdvance(UPState *state,UPPacket packet,CGRect bounds,double exponent,UPBatch *batch);
void UPCancel(UPState *state,UPBatch *batch);
void UPClear(UPBatch *batch);

// Packet pressure is zero whenever the tip is up or outside proximity.
double UPPressure(UPPacket packet,double exponent);
double UPValidatedExponent(id value);
typedef struct { bool known,invert; uint8_t held; } UPButtonState;
uint8_t UPButtonPresses(UPButtonState *state,UPPacket packet,bool capturing);
bool UPShortcutValid(uint16_t key,CGEventFlags modifiers);
bool UPShortcutEvents(uint16_t key,CGEventFlags modifiers,UPBatch *batch);
NSDictionary *UPValidatedShortcut(id value);
// Pen and touch shortcut handling is owned by the main run loop.
void UPSetShortcutCapture(bool capturing);
bool UPShortcutCaptureActive(void);
