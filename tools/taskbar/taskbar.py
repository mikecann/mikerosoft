#!/usr/bin/env python3
import logging
import os
import signal
from datetime import datetime

import objc
from AppKit import (
    NSApp,
    NSApplication,
    NSApplicationActivationPolicyAccessory,
    NSBackingStoreBuffered,
    NSBezierPath,
    NSColor,
    NSCompositingOperationSourceOver,
    NSFloatingWindowLevel,
    NSFont,
    NSFontAttributeName,
    NSForegroundColorAttributeName,
    NSLineBreakByTruncatingTail,
    NSMakeRect,
    NSParagraphStyleAttributeName,
    NSPanel,
    NSScreen,
    NSString,
    NSTimer,
    NSView,
    NSWindowCollectionBehaviorCanJoinAllSpaces,
    NSWindowCollectionBehaviorFullScreenAuxiliary,
    NSWindowCollectionBehaviorStationary,
    NSWindowStyleMaskBorderless,
    NSWindowStyleMaskNonactivatingPanel,
    NSZeroRect,
)
from Foundation import NSObject

from taskbar_model import build_taskbar_items, visible_windows
from window_provider import activate_pid, collect_window_records, current_pid, get_frontmost_pid


BAR_HEIGHT = 54
TILE_HEIGHT = 40
TILE_GAP = 7
LEFT_PAD = 10
RIGHT_PAD = 118
LOG_FILE = os.path.expanduser("~/Library/Logs/mikerosoft-taskbar.log")

_APP_DELEGATE = None


def color(red, green, blue, alpha=1.0):
    return NSColor.colorWithCalibratedRed_green_blue_alpha_(red, green, blue, alpha)


class TaskbarView(NSView):
    def initWithFrame_(self, frame):
        self = objc.super(TaskbarView, self).initWithFrame_(frame)
        if self is None:
            return None
        self._items = []
        self._tile_rects = []
        self._on_click = None
        self._status = ""
        return self

    def acceptsFirstMouse_(self, _event):
        return True

    def set_items(self, items, on_click):
        self._items = list(items)
        self._on_click = on_click
        self._status = datetime.now().strftime("%H:%M")
        self.setNeedsDisplay_(True)

    def _text_attributes(self, size=12, bold=False, active=False):
        paragraph = objc.lookUpClass("NSMutableParagraphStyle").alloc().init()
        paragraph.setLineBreakMode_(NSLineBreakByTruncatingTail)
        font = NSFont.boldSystemFontOfSize_(size) if bold else NSFont.systemFontOfSize_(size)
        text_color = color(0.94, 0.96, 0.98, 1.0) if active else color(0.78, 0.82, 0.86, 1.0)
        return {
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: text_color,
            NSParagraphStyleAttributeName: paragraph,
        }

    def _draw_text(self, value, rect, size=12, bold=False, active=False):
        NSString.stringWithString_(value).drawInRect_withAttributes_(
            rect,
            self._text_attributes(size=size, bold=bold, active=active),
        )

    def _draw_icon(self, item, rect):
        from AppKit import NSRunningApplication

        app = NSRunningApplication.runningApplicationWithProcessIdentifier_(int(item.pid))
        if app is not None and app.icon() is not None:
            app.icon().drawInRect_fromRect_operation_fraction_(
                rect,
                NSZeroRect,
                NSCompositingOperationSourceOver,
                1.0,
            )
            return

        NSColor.colorWithCalibratedWhite_alpha_(0.28, 1.0).set()
        NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(rect, 6, 6).fill()
        self._draw_text(
            item.owner[:1].upper(),
            NSMakeRect(rect.origin.x + 6, rect.origin.y + 4, 18, 18),
            12,
            True,
            True,
        )

    def _tile_width(self, bounds_width):
        count = max(1, len(self._items))
        available = max(120, bounds_width - LEFT_PAD - RIGHT_PAD)
        return max(112, min(190, (available - ((count - 1) * TILE_GAP)) / count))

    def drawRect_(self, _rect):
        bounds = self.bounds()
        NSColor.colorWithCalibratedWhite_alpha_(0.07, 0.98).set()
        NSBezierPath.bezierPathWithRect_(bounds).fill()

        self._tile_rects = []
        x = LEFT_PAD
        y = 7
        tile_width = self._tile_width(bounds.size.width)

        for item in self._items:
            tile_rect = NSMakeRect(x, y, tile_width, TILE_HEIGHT)
            self._tile_rects.append((tile_rect, item))

            if item.is_frontmost:
                fill = color(0.18, 0.34, 0.58, 0.98)
                stroke = color(0.40, 0.62, 0.92, 1.0)
            else:
                fill = color(0.16, 0.17, 0.19, 0.96)
                stroke = color(0.27, 0.29, 0.32, 1.0)

            path = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(tile_rect, 7, 7)
            fill.set()
            path.fill()
            stroke.set()
            path.stroke()

            self._draw_icon(item, NSMakeRect(x + 9, y + 8, 24, 24))

            label = item.owner if item.window_count == 1 else f"{item.owner} ({item.window_count})"
            self._draw_text(
                label,
                NSMakeRect(x + 40, y + 13, tile_width - 48, 17),
                12,
                True,
                item.is_frontmost,
            )

            x += tile_width + TILE_GAP

        self._draw_text("taskbar", NSMakeRect(bounds.size.width - 104, 20, 58, 18), 12, True, True)
        self._draw_text(self._status, NSMakeRect(bounds.size.width - 47, 20, 42, 18), 12, False, True)

    def mouseDown_(self, event):
        point = self.convertPoint_fromView_(event.locationInWindow(), None)
        for rect, item in self._tile_rects:
            inside_x = rect.origin.x <= point.x <= rect.origin.x + rect.size.width
            inside_y = rect.origin.y <= point.y <= rect.origin.y + rect.size.height
            if inside_x and inside_y and self._on_click is not None:
                self._on_click(item)
                return


class TaskbarController(NSObject):
    def init(self):
        self = objc.super(TaskbarController, self).init()
        if self is None:
            return None

        style = NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        self.panel = NSPanel.alloc().initWithContentRect_styleMask_backing_defer_(
            NSMakeRect(0, 0, 800, BAR_HEIGHT),
            style,
            NSBackingStoreBuffered,
            False,
        )
        self.panel.setTitle_("mikerosoft taskbar")
        self.panel.setOpaque_(False)
        self.panel.setBackgroundColor_(NSColor.clearColor())
        self.panel.setHasShadow_(False)
        self.panel.setHidesOnDeactivate_(False)
        self.panel.setIgnoresMouseEvents_(False)
        self.panel.setReleasedWhenClosed_(False)
        self.panel.setLevel_(NSFloatingWindowLevel)
        self.panel.setCollectionBehavior_(
            NSWindowCollectionBehaviorCanJoinAllSpaces
            | NSWindowCollectionBehaviorFullScreenAuxiliary
            | NSWindowCollectionBehaviorStationary
        )

        self.view = TaskbarView.alloc().initWithFrame_(NSMakeRect(0, 0, 800, BAR_HEIGHT))
        self.panel.setContentView_(self.view)
        self.reposition()
        return self

    def reposition(self):
        screen = NSScreen.mainScreen()
        frame = screen.frame()
        panel_frame = NSMakeRect(frame.origin.x, frame.origin.y, frame.size.width, BAR_HEIGHT)
        self.panel.setFrame_display_(panel_frame, True)
        self.view.setFrame_(NSMakeRect(0, 0, frame.size.width, BAR_HEIGHT))

    def show(self):
        self.panel.orderFrontRegardless()

    def refresh_(self, _timer):
        try:
            records = collect_window_records()
            visible = visible_windows(records, current_pid=current_pid())
            items = build_taskbar_items(visible, get_frontmost_pid())
            self.reposition()
            self.view.set_items(items, self.activate_item)
        except Exception:
            logging.exception("refresh failed")

    def activate_item(self, item):
        logging.info("activating %s pid=%s windows=%s", item.owner, item.pid, item.window_ids)
        activate_pid(item.pid)
        self.refresh_(None)


class TaskbarAppDelegate(NSObject):
    def applicationDidFinishLaunching_(self, _notification):
        self.controller = TaskbarController.alloc().init()
        self.controller.show()
        self.controller.refresh_(None)
        self.timer = NSTimer.scheduledTimerWithTimeInterval_target_selector_userInfo_repeats_(
            1.0,
            self.controller,
            "refresh:",
            None,
            True,
        )
        logging.info("taskbar ready")

    def applicationShouldTerminateAfterLastWindowClosed_(self, _sender):
        return False


def main():
    global _APP_DELEGATE

    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    logging.basicConfig(
        filename=LOG_FILE,
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    logging.info("taskbar starting pid=%s", os.getpid())

    def handle_signal(signum, _frame):
        logging.info("taskbar received signal=%s", signum)
        NSApp.terminate_(None)

    signal.signal(signal.SIGHUP, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)

    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
    _APP_DELEGATE = TaskbarAppDelegate.alloc().init()
    app.setDelegate_(_APP_DELEGATE)
    try:
        NSApp.run()
    finally:
        logging.info("taskbar event loop exited")


if __name__ == "__main__":
    main()
