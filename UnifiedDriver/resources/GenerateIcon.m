// Original offscreen vector artwork. Stock CoreGraphics/ImageIO; no AppKit or assets.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
static void rounded(CGContextRef c,CGRect r,CGFloat radius) {
    CGPathRef p=CGPathCreateWithRoundedRect(r,radius,radius,NULL);
    CGContextAddPath(c,p);CGContextFillPath(c);CGPathRelease(p);
}
int main(int argc,const char **argv) {@autoreleasepool{
    if(argc!=2)return 2;
    NSString *out=[NSString stringWithUTF8String:argv[1]];
    for(int size=16;size<=512;size*=2)for(int scale=1;scale<=2;scale++){
        if(size==64)continue;
        size_t pixels=(size_t)(size*scale);
        CGColorSpaceRef color=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef c=CGBitmapContextCreate(NULL,pixels,pixels,8,0,color,kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(color);if(!c)return 1;
        CGContextScaleCTM(c,pixels/1024.0,pixels/1024.0);
        CGContextSetRGBFillColor(c,0.055,0.09,0.16,1);rounded(c,CGRectMake(24,24,976,976),210);
        // Broad screen and bezel remain distinct at Dock and Finder sizes.
        CGContextSetRGBFillColor(c,0.16,0.24,0.33,1);rounded(c,CGRectMake(164,218,696,588),76);
        CGContextSetRGBFillColor(c,0.12,0.77,0.72,1);rounded(c,CGRectMake(208,278,608,484),34);
        // Diagonal light stylus with a navy separation stroke.
        CGContextSaveGState(c);CGContextTranslateCTM(c,492,368);CGContextRotateCTM(c,-M_PI_4);
        CGContextSetRGBFillColor(c,0.055,0.09,0.16,1);rounded(c,CGRectMake(-52,-58,104,672),48);
        CGContextSetRGBFillColor(c,0.96,0.98,0.97,1);rounded(c,CGRectMake(-32,14,64,580),28);
        CGContextBeginPath(c);CGContextMoveToPoint(c,-32,38);CGContextAddLineToPoint(c,32,38);CGContextAddLineToPoint(c,0,-34);CGContextClosePath(c);CGContextFillPath(c);
        CGContextRestoreGState(c);
        CGImageRef image=CGBitmapContextCreateImage(c);CGContextRelease(c);if(!image)return 1;
        NSString *name=[NSString stringWithFormat:@"icon_%dx%d%@.png",size,size,scale==2?@"@2x":@""];
        NSURL *url=[NSURL fileURLWithPath:[out stringByAppendingPathComponent:name]];
        CGImageDestinationRef dest=CGImageDestinationCreateWithURL((__bridge CFURLRef)url,CFSTR("public.png"),1,NULL);
        if(!dest){CGImageRelease(image);return 1;}
        CGImageDestinationAddImage(dest,image,NULL);BOOL ok=CGImageDestinationFinalize(dest);
        CFRelease(dest);CGImageRelease(image);if(!ok)return 1;
    }
}return 0;}
