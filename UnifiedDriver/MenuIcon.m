#import "MenuIcon.h"
NSImage *UPMenuIcon(UPMenuState state) {
    NSString *symbol=state==UPMenuPen?@"pencil":state==UPMenuTouch?@"hand.point.up.left.fill":@"exclamationmark";
    NSImage *image=[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    if(!image)image=[NSImage imageWithSize:NSMakeSize(18,18) flipped:NO drawingHandler:^BOOL(NSRect rect){
        (void)rect;[NSColor.blackColor set];
        NSBezierPath *p=[NSBezierPath bezierPath];p.lineWidth=2;p.lineCapStyle=NSLineCapStyleRound;p.lineJoinStyle=NSLineJoinStyleRound;
        if(state==UPMenuPen){
            [p moveToPoint:NSMakePoint(3,3)];[p lineToPoint:NSMakePoint(5,8)];[p lineToPoint:NSMakePoint(13,16)];[p lineToPoint:NSMakePoint(16,13)];[p lineToPoint:NSMakePoint(8,5)];[p closePath];
        }else if(state==UPMenuTouch){
            [p moveToPoint:NSMakePoint(6,2)];[p lineToPoint:NSMakePoint(3,8)];[p curveToPoint:NSMakePoint(7,7) controlPoint1:NSMakePoint(2,11) controlPoint2:NSMakePoint(5,10)];
            [p lineToPoint:NSMakePoint(7,15)];[p curveToPoint:NSMakePoint(11,15) controlPoint1:NSMakePoint(7,18) controlPoint2:NSMakePoint(11,18)];
            [p lineToPoint:NSMakePoint(11,10)];[p lineToPoint:NSMakePoint(15,9)];[p lineToPoint:NSMakePoint(15,5)];[p lineToPoint:NSMakePoint(13,2)];[p closePath];
        }else{
            [p moveToPoint:NSMakePoint(9,16)];[p lineToPoint:NSMakePoint(9,6)];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(8,1,2,2)] fill];
        }
        [p stroke];return YES;
    }];
    image.size=NSMakeSize(18,18);image.template=YES;return image;
}
