// Phone Mirror's fast input routes for WebDriverAgent. agent.sh copies this file into
// WebDriverAgentLib/Commands and includes it at the end of FBCustomCommands.m, so it's
// compiled without editing the Xcode project. WDA registers every FBCommandHandler class.
//
// WDA's own tap and drag routes look up the active app and snapshot its accessibility tree
// before and after every gesture, which takes seconds on older phones. These routes hand the
// touch straight to XCTest's event synthesizer at screen coordinates, as WDA's typing does.

#import "FBXCTestDaemonsProxy.h"
#import "XCPointerEventPath.h"
#import "XCSynthesizedEventRecord.h"

@interface PMFastInputCommands : NSObject <FBCommandHandler>
@end

@implementation PMFastInputCommands

+ (NSArray *)routes
{
  return @[
    [[FBRoute POST:@"/phonemirror/touch"].withoutSession respondWithTarget:self action:@selector(handleTouch:)],
    [[FBRoute GET:@"/phonemirror/orientation"].withoutSession respondWithTarget:self action:@selector(handleOrientation:)],
    [[FBRoute POST:@"/phonemirror/nudge"].withoutSession respondWithTarget:self action:@selector(handleNudge:)],
  ];
}

/// Presses and releases Shift. It types nothing and touches nothing, but it's input, so it
/// resets the phone's auto-lock timer. Phone Mirror sends it every so often to keep a mirrored
/// phone awake.
+ (id<FBResponsePayload>)handleNudge:(FBRouteRequest *)request
{
  XCPointerEventPath *path = [[XCPointerEventPath alloc] initForTextInput];
  [path setModifiers:XCUIKeyModifierShift mergeWithCurrentModifierFlags:NO atOffset:0];
  [path setModifiers:XCUIKeyModifierNone mergeWithCurrentModifierFlags:NO atOffset:0.05];
  XCSynthesizedEventRecord *record = [[XCSynthesizedEventRecord alloc] initWithName:@"Phone Mirror nudge"
                                                               interfaceOrientation:UIInterfaceOrientationPortrait];
  [record addPointerEventPath:path];
  NSError *error;
  if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:&error]) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:error.localizedDescription
                                                               traceback:nil]);
  }
  return FBResponseWithOK();
}

/// Body: {"points": [{"x": 10, "y": 20, "t": 0}, ...], "hold": 0.05, "orientation": 1}
/// The finger goes down at the first point, moves through the rest at their times (seconds),
/// and lifts `hold` seconds after the last one. Coordinates are points in `orientation`
/// (a UIInterfaceOrientation value, portrait if omitted).
+ (id<FBResponsePayload>)handleTouch:(FBRouteRequest *)request
{
  NSArray<NSDictionary *> *points = request.arguments[@"points"];
  if (![points isKindOfClass:NSArray.class] || points.count == 0) {
    return FBResponseWithStatus([FBCommandStatus invalidArgumentErrorWithMessage:@"'points' must be a non-empty array"
                                                                       traceback:nil]);
  }
  XCPointerEventPath *path = nil;
  double offset = 0;
  for (NSDictionary *point in points) {
    CGPoint location = CGPointMake([point[@"x"] doubleValue], [point[@"y"] doubleValue]);
    offset = [point[@"t"] doubleValue];
    if (nil == path) {
      path = [[XCPointerEventPath alloc] initForTouchAtPoint:location offset:offset];
    } else {
      [path moveToPoint:location atOffset:offset];
    }
  }
  [path liftUpAtOffset:offset + MAX([request.arguments[@"hold"] doubleValue], 0.03)];

  long long orientation = [request.arguments[@"orientation"] longLongValue] ?: UIInterfaceOrientationPortrait;
  XCSynthesizedEventRecord *record = [[XCSynthesizedEventRecord alloc] initWithName:@"Phone Mirror touch"
                                                               interfaceOrientation:orientation];
  [record addPointerEventPath:path];
  NSError *error;
  if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:&error]) {
    return FBResponseWithStatus([FBCommandStatus unknownErrorWithMessage:error.localizedDescription
                                                               traceback:nil]);
  }
  return FBResponseWithOK();
}

/// The active app's UIInterfaceOrientation. WDA's /orientation reports both landscapes as
/// "LANDSCAPE", which isn't enough to place touches. This snapshots the app, so it's slow:
/// call it when the screen rotates, not per touch.
+ (id<FBResponsePayload>)handleOrientation:(FBRouteRequest *)request
{
  return FBResponseWithObject(@(XCUIApplication.fb_activeApplication.interfaceOrientation));
}

@end
