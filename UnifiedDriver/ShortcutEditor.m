#import "ShortcutEditor.h"
@implementation UPShortcutEditor
- (BOOL)acceptsFirstResponder {return YES;}
- (void)updateTitle {
    if(self.recording){self.title=@"Type shortcut… (Esc cancels)";return;}
    if(![self.binding isKindOfClass:NSDictionary.class]){self.title=@"Unassigned — Record shortcut";return;}
    CGEventFlags flags=[self.binding[@"modifiers"] unsignedLongLongValue];
    NSString *name=self.binding[@"name"];
    if(!name.length)name=[NSString stringWithFormat:@"Key %@",self.binding[@"key"]];
    self.title=[NSString stringWithFormat:@"%@%@%@%@%@",flags&kCGEventFlagMaskControl?@"⌃":@"",flags&kCGEventFlagMaskAlternate?@"⌥":@"",flags&kCGEventFlagMaskShift?@"⇧":@"",flags&kCGEventFlagMaskCommand?@"⌘":@"",[name stringByAppendingString:@" — Record shortcut"]];
}
- (void)setBinding:(id)binding {_binding=binding;[self updateTitle];}
- (instancetype)initWithFrame:(NSRect)frame {
    if((self=[super initWithFrame:frame])){self.target=self;self.action=@selector(beginRecording:);}
    return self;
}
- (void)beginRecording:(id)sender {
    (void)sender;
    if([self.window makeFirstResponder:self]){self.recording=YES;[BTPenMonitor setShortcutCapture:YES];[self updateTitle];}
}
- (BOOL)resignFirstResponder {
    self.recording=NO;[BTPenMonitor setShortcutCapture:NO];[self updateTitle];return YES;
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if(self.recording){[self keyDown:event];return YES;}return [super performKeyEquivalent:event];
}
- (void)keyDown:(NSEvent *)event {
    if(!self.recording){[super keyDown:event];return;}
    if(event.isARepeat)return;
    if(event.keyCode==53){[self.window makeFirstResponder:nil];return;}
    CGEventFlags mods=event.modifierFlags & (NSEventModifierFlagCommand|NSEventModifierFlagOption|NSEventModifierFlagShift|NSEventModifierFlagControl);
    if(!UPShortcutValid(event.keyCode,mods))return;
    NSString *name=event.charactersIgnoringModifiers.uppercaseString?:@"";
    NSDictionary *special=@{@36:@"Return",@48:@"Tab",@49:@"Space",@51:@"Delete",@76:@"Enter",@114:@"Help",@115:@"Home",@116:@"Page Up",@117:@"Forward Delete",@119:@"End",@121:@"Page Down",@123:@"←",@124:@"→",@125:@"↓",@126:@"↑"};
    name=special[@(event.keyCode)]?:name;
    // AppKit function-key characters are private-use glyphs; give them a readable name.
    if(name.length && [name characterAtIndex:0]>=NSF1FunctionKey && [name characterAtIndex:0]<=NSF20FunctionKey)name=[NSString stringWithFormat:@"F%u",[name characterAtIndex:0]-NSF1FunctionKey+1];
    NSDictionary *binding=@{@"key":@(event.keyCode),@"modifiers":@(mods),@"name":name};
    self.binding=binding;if(self.bindingChanged)self.bindingChanged(binding);
    [self.window makeFirstResponder:nil];
}
- (void)keyUp:(NSEvent *)event {if(!self.recording)[super keyUp:event];}
@end
