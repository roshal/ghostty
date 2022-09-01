//! Screen represents the internal storage for a terminal screen, including
//! scrollback. This is implemented as a single continuous ring buffer.
//!
//! Definitions:
//!
//!   * Screen - The full screen (active + history).
//!   * Active - The area that is the current edit-able screen (the
//!       bottom of the scrollback). This is "edit-able" because it is
//!       the only part that escape sequences such as set cursor position
//!       actually affect.
//!   * History - The area that contains the lines prior to the active
//!       area. This is the scrollback area. Escape sequences can no longer
//!       affect this area.
//!   * Viewport - The area that is currently visible to the user. This
//!       can be thought of as the current window into the screen.
//!
const Screen = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const utf8proc = @import("utf8proc");
const color = @import("color.zig");
const point = @import("point.zig");
const CircBuf = @import("circ_buf.zig").CircBuf;
const Selection = @import("Selection.zig");

const log = std.log.scoped(.screen);

/// Cursor represents the cursor state.
pub const Cursor = struct {
    // x, y where the cursor currently exists (0-indexed). This x/y is
    // always the offset in the active area.
    x: usize = 0,
    y: usize = 0,

    // pen is the current cell styling to apply to new cells.
    pen: Cell = .{ .char = 0 },

    // The last column flag (LCF) used to do soft wrapping.
    pending_wrap: bool = false,
};

/// This is a single item within the storage buffer. We use a union to
/// have different types of data in a single contiguous buffer.
const StorageCell = union {
    header: RowHeader,
    cell: Cell,

    test {
        // log.warn("header={}@{} cell={}@{} storage={}@{}", .{
        //     @sizeOf(RowHeader),
        //     @alignOf(RowHeader),
        //     @sizeOf(Cell),
        //     @alignOf(Cell),
        //     @sizeOf(StorageCell),
        //     @alignOf(StorageCell),
        // });
    }

    comptime {
        // We only check this during ReleaseFast because safety checks
        // have to be disabled to get this size.
        if (builtin.mode == .ReleaseFast) {
            // We want to be at most the size of a cell always. We have WAY
            // more cells than other fields, so we don't want to pay the cost
            // of padding due to other fields.
            assert(@sizeOf(Cell) == @sizeOf(StorageCell));
        } else {
            // Extra u32 for the tag for safety checks. This is subject to
            // change depending on the Zig compiler...
            assert((@sizeOf(Cell) + @sizeOf(u32)) == @sizeOf(StorageCell));
        }
    }
};

/// The row header is at the start of every row within the storage buffer.
/// It can store row-specific data.
pub const RowHeader = struct {
    /// Used internally to track if this row has been initialized.
    init: bool = false,

    /// True if one of the cells in this row has been changed
    dirty: bool = false,

    /// If true, this row is soft-wrapped. The first cell of the next
    /// row is a continuous of this row.
    wrap: bool = false,
};

/// Cell is a single cell within the screen.
pub const Cell = struct {
    /// The primary unicode codepoint for this cell. Most cells (almost all)
    /// contain exactly one unicode codepoint. However, it is possible for
    /// cells to contain multiple if multiple codepoints are used to create
    /// a single grapheme cluster.
    ///
    /// In the case multiple codepoints make up a single grapheme, the
    /// additional codepoints can be looked up in the hash map on the
    /// Screen. Since multi-codepoints graphemes are rare, we don't want to
    /// waste memory for every cell, so we use a side lookup for it.
    char: u32 = 0,

    /// Foreground and background color. attrs.has_{bg/fg} must be checked
    /// to see if these are useful values.
    fg: color.RGB = undefined,
    bg: color.RGB = undefined,

    /// On/off attributes that can be set
    attrs: packed struct {
        has_bg: bool = false,
        has_fg: bool = false,

        bold: bool = false,
        faint: bool = false,
        underline: bool = false,
        inverse: bool = false,

        /// True if this is a wide character. This char takes up
        /// two cells. The following cell ALWAYS is a space.
        wide: bool = false,

        /// Notes that this only exists to be blank for a preceeding
        /// wide character (tail) or following (head).
        wide_spacer_tail: bool = false,
        wide_spacer_head: bool = false,
    } = .{},

    /// True if the cell should be skipped for drawing
    pub fn empty(self: Cell) bool {
        return self.char == 0;
    }

    test {
        // We use this test to ensure we always get the right size of the attrs
        // const cell: Cell = .{ .char = 0 };
        // _ = @bitCast(u8, cell.attrs);
        // try std.testing.expectEqual(1, @sizeOf(@TypeOf(cell.attrs)));
    }

    test {
        //log.warn("CELL={} {}", .{ @sizeOf(Cell), @alignOf(Cell) });
        try std.testing.expectEqual(12, @sizeOf(Cell));
    }
};

/// A row is a single row in the screen.
pub const Row = struct {
    /// Raw internal storage, do NOT write to this, use only the
    /// helpers. Writing directly to this can easily mess up state
    /// causing future crashes or misrendering.
    storage: []StorageCell,

    /// Set that this row is soft-wrapped. This doesn't change the contents
    /// of this row so the row won't be marked dirty.
    pub fn setWrapped(self: Row, v: bool) void {
        self.storage[0].header.wrap = v;
    }

    /// Retrieve the header for this row.
    pub fn header(self: Row) RowHeader {
        return self.storage[0].header;
    }

    /// Returns the number of cells in this row.
    pub fn lenCells(self: Row) usize {
        return self.storage.len - 1;
    }

    /// Clear the row, making all cells empty.
    pub fn clear(self: Row, pen: Cell) void {
        var empty_pen = pen;
        empty_pen.char = 0;
        self.fill(empty_pen);
    }

    /// Fill the entire row with a copy of a single cell.
    pub fn fill(self: Row, cell: Cell) void {
        std.mem.set(StorageCell, self.storage[1..], .{ .cell = cell });
    }

    /// Fill a slice of a row.
    pub fn fillSlice(self: Row, cell: Cell, start: usize, len: usize) void {
        assert(len <= self.storage.len - 1);
        std.mem.set(StorageCell, self.storage[start + 1 .. len + 1], .{ .cell = cell });
    }

    /// Get a single immutable cell.
    pub fn getCell(self: Row, x: usize) Cell {
        assert(self.header().init);
        assert(x < self.storage.len - 1);
        return self.storage[x + 1].cell;
    }

    /// Get a pointr to the cell at column x (0-indexed). This always
    /// assumes that the cell was modified, notifying the renderer on the
    /// next call to re-render this cell. Any change detection to avoid
    /// this should be done prior.
    pub fn getCellPtr(self: Row, x: usize) *Cell {
        assert(self.header().init);
        assert(x < self.storage.len - 1);
        return &self.storage[x + 1].cell;
    }

    /// Copy the row src into this row. The row can be from another screen.
    pub fn copyRow(self: Row, src: Row) void {
        assert(self.header().init);
        const end = @minimum(src.storage.len, self.storage.len);
        std.mem.copy(StorageCell, self.storage[1..], src.storage[1..end]);
    }

    /// Read-only iterator for the cells in the row.
    pub fn cellIterator(self: Row) CellIterator {
        assert(self.header().init);
        return .{ .row = self };
    }

    /// If this row isn't initialized, this sets all our cells to the
    /// proper union tag so that it is properly zeroed.
    fn initIfNeeded(self: Row) void {
        if (!self.storage[0].header.init) {
            self.fill(.{});
            self.storage[0].header.init = true;
        }
    }
};

/// Used to iterate through the rows of a specific region.
pub const RowIterator = struct {
    screen: *Screen,
    tag: RowIndexTag,
    value: usize = 0,

    pub fn next(self: *RowIterator) ?Row {
        if (self.value >= self.tag.maxLen(self.screen)) return null;
        const idx = self.tag.index(self.value);
        const res = self.screen.getRow(idx);
        self.value += 1;
        return res;
    }
};

/// Used to iterate through the rows of a specific region.
pub const CellIterator = struct {
    row: Row,
    i: usize = 0,

    pub fn next(self: *CellIterator) ?Cell {
        if (self.i >= self.row.storage.len - 1) return null;
        const res = self.row.storage[self.i + 1].cell;
        self.i += 1;
        return res;
    }
};

/// RowIndex represents a row within the screen. There are various meanings
/// of a row index and this union represents the available types. For example,
/// when talking about row "0" you may want the first row in the viewport,
/// the first row in the scrollback, or the first row in the active area.
///
/// All row indexes are 0-indexed.
pub const RowIndex = union(RowIndexTag) {
    /// The index is from the top of the screen. The screen includes all
    /// the history.
    screen: usize,

    /// The index is from the top of the viewport. Therefore, depending
    /// on where the user has scrolled the viewport, "0" is different.
    viewport: usize,

    /// The index is from the top of the active area. The active area is
    /// always "rows" tall, and 0 is the top row. The active area is the
    /// "edit-able" area where the terminal cursor is.
    active: usize,

    /// The index is from the top of the history (scrollback) to just
    /// prior to the active area.
    history: usize,

    /// Convert this row index into a screen offset. This will validate
    /// the value so even if it is already a screen value, this may error.
    pub fn toScreen(self: RowIndex, screen: *const Screen) RowIndex {
        const y = switch (self) {
            .screen => |y| y: {
                assert(y < RowIndexTag.screen.maxLen(screen));
                break :y y;
            },

            .viewport => |y| y: {
                assert(y < RowIndexTag.viewport.maxLen(screen));
                break :y y + screen.viewport;
            },

            .active => |y| y: {
                assert(y < RowIndexTag.active.maxLen(screen));
                break :y RowIndexTag.history.maxLen(screen) + y;
            },

            .history => |y| y: {
                assert(y < RowIndexTag.history.maxLen(screen));
                break :y y;
            },
        };

        return .{ .screen = y };
    }
};

/// The tags of RowIndex
pub const RowIndexTag = enum {
    screen,
    viewport,
    active,
    history,

    /// The max length for a given tag. This is a length, not an index,
    /// so it is 1-indexed. If the value is zero, it means that this
    /// section of the screen is empty or disabled.
    pub fn maxLen(self: RowIndexTag, screen: *const Screen) usize {
        const rows_written = screen.rowsWritten();

        return switch (self) {
            // Screen can be any of the written rows
            .screen => rows_written,

            // Viewport can be any of the written rows or the max size
            // of a viewport.
            .viewport => @minimum(screen.rows, rows_written),

            // History is all the way up to the top of our active area. If
            // we haven't filled our active area, there is no history.
            .history => if (rows_written > screen.rows) rows_written - screen.rows else 0,

            // Active area can be any number of rows. We ignore rows
            // written here because this is the only row index that can
            // actively grow our rows.
            .active => screen.rows,
            //TODO .active => @minimum(rows_written, screen.rows),
        };
    }

    /// Construct a RowIndex from a tag.
    pub fn index(self: RowIndexTag, value: usize) RowIndex {
        return switch (self) {
            .screen => .{ .screen = value },
            .viewport => .{ .viewport = value },
            .active => .{ .active = value },
            .history => .{ .history = value },
        };
    }
};

// Initialize to header and not a cell so that we can check header.init
// to know if the remainder of the row has been initialized or not.
const StorageBuf = CircBuf(StorageCell, .{ .header = .{} });

/// The allocator used for all the storage operations
alloc: Allocator,

/// The full set of storage.
storage: StorageBuf,

/// The number of rows and columns in the visible space.
rows: usize,
cols: usize,

/// The maximum number of lines that are available in scrollback. This
/// is in addition to the number of visible rows.
max_scrollback: usize,

/// The row (offset from the top) where the viewport currently is.
viewport: usize,

/// Each screen maintains its own cursor state.
cursor: Cursor = .{},

/// Saved cursor saved with DECSC (ESC 7).
saved_cursor: Cursor = .{},

/// Initialize a new screen.
pub fn init(
    alloc: Allocator,
    rows: usize,
    cols: usize,
    max_scrollback: usize,
) !Screen {
    // * Our buffer size is preallocated to fit double our visible space
    //   or the maximum scrollback whichever is smaller.
    // * We add +1 to cols to fit the row header
    const buf_size = (rows + @minimum(max_scrollback, rows)) * (cols + 1);

    return Screen{
        .alloc = alloc,
        .storage = try StorageBuf.init(alloc, buf_size),
        .rows = rows,
        .cols = cols,
        .max_scrollback = max_scrollback,
        .viewport = 0,
    };
}

pub fn deinit(self: *Screen) void {
    self.storage.deinit(self.alloc);
}

/// Returns true if the viewport is scrolled to the bottom of the screen.
pub fn viewportIsBottom(self: Screen) bool {
    return self.viewport >= RowIndexTag.history.maxLen(&self);
}

/// Shortcut for getRow followed by getCell as a quick way to read a cell.
/// This is particularly useful for quickly reading the cell under a cursor
/// with `getCell(.active, cursor.y, cursor.x)`.
pub fn getCell(self: *Screen, tag: RowIndexTag, y: usize, x: usize) Cell {
    return self.getRow(tag.index(y)).getCell(x);
}

/// Shortcut for getRow followed by getCellPtr as a quick way to read a cell.
pub fn getCellPtr(self: *Screen, tag: RowIndexTag, y: usize, x: usize) *Cell {
    return self.getRow(tag.index(y)).getCellPtr(x);
}

/// Returns an iterator that can be used to iterate over all of the rows
/// from index zero of the given row index type. This can therefore iterate
/// from row 0 of the active area, history, viewport, etc.
pub fn rowIterator(self: *Screen, tag: RowIndexTag) RowIterator {
    return .{ .screen = self, .tag = tag };
}

/// Returns the row at the given index. This row is writable, although
/// only the active area should probably be written to.
pub fn getRow(self: *Screen, index: RowIndex) Row {
    // Get our offset into storage
    const offset = index.toScreen(self).screen * (self.cols + 1);

    // Get the slices into the storage. This should never wrap because
    // we're perfectly aligned on row boundaries.
    const slices = self.storage.getPtrSlice(offset, self.cols + 1);
    assert(slices[0].len == self.cols + 1 and slices[1].len == 0);

    const row: Row = .{ .storage = slices[0] };
    row.initIfNeeded();
    return row;
}

/// Copy the row at src to dst.
pub fn copyRow(self: *Screen, dst: RowIndex, src: RowIndex) void {
    // One day we can make this more efficient but for now
    // we do the easy thing.
    const dst_row = self.getRow(dst);
    const src_row = self.getRow(src);
    dst_row.copyRow(src_row);
}

/// Returns the offset into the storage buffer that the given row can
/// be found. This assumes valid input and will crash if the input is
/// invalid.
fn rowOffset(self: Screen, index: RowIndex) usize {
    // +1 for row header
    return index.toScreen(&self).screen * (self.cols + 1);
}

/// Returns the number of rows that have actually been written to the
/// screen. This assumes a row is "written" if getRow was ever called
/// on the row.
fn rowsWritten(self: Screen) usize {
    // The number of rows we've actually written into our buffer
    // This should always be cleanly divisible since we only request
    // data in row chunks from the buffer.
    assert(@mod(self.storage.len(), self.cols + 1) == 0);
    return self.storage.len() / (self.cols + 1);
}

/// The number of rows our backing storage supports. This should
/// always be self.rows but we use the backing storage as a source of truth.
fn rowsCapacity(self: Screen) usize {
    assert(@mod(self.storage.capacity(), self.cols + 1) == 0);
    return self.storage.capacity() / (self.cols + 1);
}

/// The maximum possible capacity of the underlying buffer if we reached
/// the max scrollback.
fn maxCapacity(self: Screen) usize {
    return (self.rows + self.max_scrollback) * (self.cols + 1);
}

/// Scroll behaviors for the scroll function.
pub const Scroll = union(enum) {
    /// Scroll to the top of the scroll buffer. The first line of the
    /// viewport will be the top line of the scroll buffer.
    top: void,

    /// Scroll to the bottom, where the last line of the viewport
    /// will be the last line of the buffer. TODO: are we sure?
    bottom: void,

    /// Scroll up (negative) or down (positive) some fixed amount.
    /// Scrolling direction (up/down) describes the direction the viewport
    /// moves, not the direction text moves. This is the colloquial way that
    /// scrolling is described: "scroll the page down".
    delta: isize,

    /// Same as delta but scrolling down will not grow the scrollback.
    /// Scrolling down at the bottom will do nothing (similar to how
    /// delta at the top does nothing).
    delta_no_grow: isize,
};

/// Scroll the screen by the given behavior. Note that this will always
/// "move" the screen. It is up to the caller to determine if they actually
/// want to do that yet (i.e. are they writing to the end of the screen
/// or not).
pub fn scroll(self: *Screen, behavior: Scroll) !void {
    switch (behavior) {
        // Setting viewport offset to zero makes row 0 be at self.top
        // which is the top!
        .top => self.viewport = 0,

        // Bottom is the end of the history area (end of history is the
        // top of the active area).
        .bottom => self.viewport = RowIndexTag.history.maxLen(self),

        // TODO: deltas greater than the entire scrollback
        .delta => |delta| try self.scrollDelta(delta, true),
        .delta_no_grow => |delta| try self.scrollDelta(delta, false),
    }
}

fn scrollDelta(self: *Screen, delta: isize, grow: bool) !void {
    // If we're scrolling up, then we just subtract and we're done.
    // We just clamp at 0 which blocks us from scrolling off the top.
    if (delta < 0) {
        self.viewport -|= @intCast(usize, -delta);
        return;
    }

    // If we're scrolling down and not growing, then we just
    // add to the viewport and clamp at the bottom.
    const viewport_max = RowIndexTag.history.maxLen(self);
    if (!grow) {
        self.viewport = @minimum(
            viewport_max,
            self.viewport +| @intCast(usize, delta),
        );
        return;
    }

    // Add our delta to our viewport. If we're less than the max currently
    // allowed to scroll to the bottom (the end of the history), then we
    // have space and we just return.
    self.viewport +|= @intCast(usize, delta);
    if (self.viewport <= viewport_max) return;

    // Our viewport is bigger than our max. The number of new rows we need
    // in our buffer is our value minus the max.
    const new_rows_needed = self.viewport - viewport_max;

    // If we can't fit into our capacity but we have space, resize the
    // buffer to allocate more scrollback.
    const rows_written = self.rowsWritten();
    const rows_final = rows_written + new_rows_needed;
    if (rows_final > self.rowsCapacity()) {
        const max_capacity = self.maxCapacity();
        if (self.storage.capacity() < max_capacity) {
            // The capacity we want to allocate. We take whatever is greater
            // of what we actually need and two pages. We don't want to
            // allocate one row at a time (common for scrolling) so we do this
            // to chunk it.
            const needed_capacity = @maximum(
                rows_final * (self.cols + 1),
                @minimum(self.storage.capacity() * 2, max_capacity),
            );

            // Allocate what we can.
            try self.storage.resize(
                self.alloc,
                @minimum(max_capacity, needed_capacity),
            );
        }
    }

    // If we can't fit our rows into our capacity, we delete some scrollback.
    const rows_deleted = if (rows_final > self.rowsCapacity()) deleted: {
        const rows_to_delete = rows_final - self.rowsCapacity();
        self.viewport -= rows_to_delete;
        self.storage.deleteOldest(rows_to_delete * (self.cols + 1));

        // If we grew down like this, we must be at the bottom.
        assert(self.viewportIsBottom());

        break :deleted rows_to_delete;
    } else 0;

    // Ensure we have "written" our last row so that it shows up
    _ = self.storage.getPtrSlice(
        (rows_final - rows_deleted - 1) * (self.cols + 1),
        self.cols + 1,
    );
}

/// Returns the raw text associated with a selection. This will unwrap
/// soft-wrapped edges. The returned slice is owned by the caller and allocated
/// using alloc, not the allocator associated with the screen (unless they match).
pub fn selectionString(self: *Screen, alloc: Allocator, sel: Selection) ![:0]const u8 {
    // Get the slices for the string
    const slices = self.selectionSlices(sel);

    // We can now know how much space we'll need to store the string. We loop
    // over and UTF8-encode and calculate the exact size required. We will be
    // off here by at most "newlines" values in the worst case that every
    // single line is soft-wrapped.
    const chars = chars: {
        var count: usize = 0;
        const arr = [_][]StorageCell{ slices.top, slices.bot };
        for (arr) |slice| {
            for (slice) |cell, i| {
                // detect row headers
                if (@mod(i, self.cols + 1) == 0) {
                    // We use each row header as an opportunity to "count"
                    // a new row, and therefore count a possible newline.
                    count += 1;
                    continue;
                }

                var buf: [4]u8 = undefined;
                const char = if (cell.cell.char > 0) cell.cell.char else ' ';
                count += try std.unicode.utf8Encode(@intCast(u21, char), &buf);
            }
        }

        break :chars count;
    };
    const buf = try alloc.alloc(u8, chars + 1);
    errdefer alloc.free(buf);

    // Connect the text from the two slices
    const arr = [_][]StorageCell{ slices.top, slices.bot };
    var buf_i: usize = 0;
    var row_count: usize = 0;
    for (arr) |slice| {
        var row_start: usize = row_count;
        while (row_count < slices.rows) : (row_count += 1) {
            const row_i = row_count - row_start;

            // Calculate our start index. If we are beyond the length
            // of this slice, then its time to move on (we exhausted top).
            const start_idx = row_i * (self.cols + 1);
            if (start_idx >= slice.len) break;

            // Our end index is usually a full row, but if we're the final
            // row then we just use the length.
            const end_idx = @minimum(slice.len, start_idx + self.cols + 1);

            // We may have to skip some cells from the beginning if we're
            // the first row.
            var skip: usize = if (row_count == 0) slices.top_offset else 0;

            const row: Row = .{ .storage = slice[start_idx..end_idx] };
            var it = row.cellIterator();
            while (it.next()) |cell| {
                if (skip > 0) {
                    skip -= 1;
                    continue;
                }

                // Skip spacers
                if (cell.attrs.wide_spacer_head or
                    cell.attrs.wide_spacer_tail) continue;

                const char = if (cell.char > 0) cell.char else ' ';
                buf_i += try std.unicode.utf8Encode(@intCast(u21, char), buf[buf_i..]);
            }

            // If this row is not soft-wrapped, add a newline
            if (!row.header().wrap) {
                buf[buf_i] = '\n';
                buf_i += 1;
            }
        }
    }

    // Remove our trailing newline, its never correct.
    if (buf[buf_i - 1] == '\n') buf_i -= 1;

    // Add null termination
    buf[buf_i] = 0;

    // Realloc so our free length is exactly correct
    const result = try alloc.realloc(buf, buf_i + 1);
    return result[0..buf_i :0];
}

/// Returns the slices that make up the selection, in order. There are at most
/// two parts to handle the ring buffer. If the selection fits in one contiguous
/// slice, then the second slice will have a length of zero.
fn selectionSlices(self: *Screen, sel_raw: Selection) struct {
    rows: usize,

    // Top offset can be used to determine if a newline is required by
    // seeing if the cell index plus the offset cleanly divides by screen cols.
    top_offset: usize,
    top: []StorageCell,
    bot: []StorageCell,
} {
    // Note: this function is tested via selectionString

    assert(sel_raw.start.y < self.rowsWritten());
    assert(sel_raw.end.y < self.rowsWritten());
    assert(sel_raw.start.x < self.cols);
    assert(sel_raw.end.x < self.cols);

    const sel = sel: {
        var sel = sel_raw;

        // If the end of our selection is a wide char leader, include the
        // first part of the next line.
        if (sel.end.x == self.cols - 1) {
            const row = self.getRow(.{ .screen = sel.end.y });
            const cell = row.getCell(sel.end.x);
            if (cell.attrs.wide_spacer_head) {
                sel.end.y += 1;
                sel.end.x = 0;
            }
        }

        // If the start of our selection is a wide char spacer, include the
        // wide char.
        if (sel.start.x > 0) {
            const row = self.getRow(.{ .screen = sel.start.y });
            const cell = row.getCell(sel.start.x);
            if (cell.attrs.wide_spacer_tail) {
                sel.end.x -= 1;
            }
        }

        break :sel sel;
    };

    // Get the true "top" and "bottom"
    const sel_top = sel.topLeft();
    const sel_bot = sel.bottomRight();

    // We get the slices for the full top and bottom (inclusive).
    const sel_top_offset = self.rowOffset(.{ .screen = sel_top.y });
    const sel_bot_offset = self.rowOffset(.{ .screen = sel_bot.y });
    const slices = self.storage.getPtrSlice(
        sel_top_offset,
        (sel_bot_offset - sel_top_offset) + (sel_bot.x + 2),
    );

    // The bottom and top are split into two slices, so we slice to the
    // bottom of the storage, then from the top.
    return .{
        .rows = sel_bot.y - sel_top.y + 1,
        .top_offset = sel_top.x,
        .top = slices[0],
        .bot = slices[1],
    };
}

/// Resize the screen without any reflow. In this mode, columns/rows will
/// be truncated as they are shrunk. If they are grown, the new space is filled
/// with zeros.
pub fn resizeWithoutReflow(self: *Screen, rows: usize, cols: usize) !void {
    // Make a copy so we can access the old indexes.
    var old = self.*;
    errdefer self.* = old;

    // Change our rows and cols so calculations make sense
    self.rows = rows;
    self.cols = cols;

    // Calculate our buffer size. This is going to be either the old data
    // with scrollback or the max capacity of our new size. We prefer the old
    // length so we can save all the data (ignoring col truncation).
    const old_len = @maximum(old.rowsWritten(), rows) * (cols + 1);
    const new_max_capacity = self.maxCapacity();
    const buf_size = @minimum(old_len, new_max_capacity);

    // Reallocate the storage
    self.storage = try StorageBuf.init(self.alloc, buf_size);
    errdefer self.storage.deinit(self.alloc);
    defer old.storage.deinit(self.alloc);

    // Our viewport resets to the top because we're going to rewrite the screen
    self.viewport = 0;

    // Rewrite all our rows
    var y: usize = 0;
    var row_it = old.rowIterator(.screen);
    while (row_it.next()) |old_row| {
        // If we're past the end, scroll
        if (y >= self.rows) {
            y -= 1;
            try self.scroll(.{ .delta = 1 });
        }

        // Get this row
        const new_row = self.getRow(.{ .active = y });
        new_row.copyRow(old_row);

        // Next row
        y += 1;
    }

    // Convert our cursor to screen coordinates so we can preserve it.
    // The cursor is normally in active coordinates, but by converting to
    // screen we can accomodate keeping it on the same place if we retain
    // the same scrollback.
    const old_cursor_y_screen = RowIndexTag.active.index(old.cursor.y).toScreen(&old).screen;
    self.cursor.x = @minimum(old.cursor.x, self.cols - 1);
    self.cursor.y = if (old_cursor_y_screen < RowIndexTag.screen.maxLen(self))
        old_cursor_y_screen - RowIndexTag.history.maxLen(self)
    else
        self.rows - 1;
}

/// Resize the screen. The rows or cols can be bigger or smaller. This
/// function can only be used to resize the viewport. The scrollback size
/// (in lines) can't be changed. But due to the resize, more or less scrollback
/// "space" becomes available due to the width of lines.
///
/// Due to the internal representation of a screen, this usually involves a
/// significant amount of copying compared to any other operations.
///
/// This will trim data if the size is getting smaller. This will reflow the
/// soft wrapped text.
pub fn resize(self: *Screen, rows: usize, cols: usize) !void {
    if (self.cols == cols) {
        // No resize necessary
        if (self.rows == rows) return;

        // If we have the same number of columns, text can't possibly
        // reflow in any way, so we do the quicker thing and do a resize
        // without reflow checks.
        try self.resizeWithoutReflow(rows, cols);
        return;
    }

    // TODO
    try self.resizeWithoutReflow(rows, cols);
}

/// Writes a basic string into the screen for testing. Newlines (\n) separate
/// each row. If a line is longer than the available columns, soft-wrapping
/// will occur. This will automatically handle basic wide chars.
pub fn testWriteString(self: *Screen, text: []const u8) !void {
    var y: usize = 0;
    var x: usize = 0;

    const view = std.unicode.Utf8View.init(text) catch unreachable;
    var iter = view.iterator();
    while (iter.nextCodepoint()) |c| {
        // Explicit newline forces a new row
        if (c == '\n') {
            y += 1;
            x = 0;
            continue;
        }

        // If we're writing past the end of the active area, scroll.
        if (y >= self.rows) {
            y -= 1;
            try self.scroll(.{ .delta = 1 });
        }

        // Get our row
        var row = self.getRow(.{ .active = y });

        // If we're writing past the end, we need to soft wrap.
        if (x == self.cols) {
            row.setWrapped(true);
            y += 1;
            x = 0;
            if (y >= self.rows) {
                y -= 1;
                try self.scroll(.{ .delta = 1 });
            }
            row = self.getRow(.{ .active = y });
        }

        // If our character is double-width, handle it.
        const width = utf8proc.charwidth(c);
        assert(width == 1 or width == 2);
        switch (width) {
            1 => {
                const cell = row.getCellPtr(x);
                cell.char = @intCast(u32, c);
            },

            2 => {
                if (x == self.cols - 1) {
                    const cell = row.getCellPtr(x);
                    cell.char = ' ';
                    cell.attrs.wide_spacer_head = true;

                    // wrap
                    row.setWrapped(true);
                    y += 1;
                    x = 0;
                    if (y >= self.rows) {
                        y -= 1;
                        try self.scroll(.{ .delta = 1 });
                    }
                    row = self.getRow(.{ .active = y });
                }

                {
                    const cell = row.getCellPtr(x);
                    cell.char = @intCast(u32, c);
                    cell.attrs.wide = true;
                }

                {
                    x += 1;
                    const cell = row.getCellPtr(x);
                    cell.char = ' ';
                    cell.attrs.wide_spacer_tail = true;
                }
            },

            else => unreachable,
        }

        x += 1;
    }
}

/// Turns the screen into a string. Different regions of the screen can
/// be selected using the "tag", i.e. if you want to output the viewport,
/// the scrollback, the full screen, etc.
///
/// This is only useful for testing.
pub fn testString(self: *Screen, alloc: Allocator, tag: RowIndexTag) ![]const u8 {
    const buf = try alloc.alloc(u8, self.storage.len() * 4);

    var i: usize = 0;
    var y: usize = 0;
    var rows = self.rowIterator(tag);
    while (rows.next()) |row| {
        defer y += 1;

        if (y > 0) {
            buf[i] = '\n';
            i += 1;
        }

        var cells = row.cellIterator();
        while (cells.next()) |cell| {
            // TODO: handle character after null
            if (cell.char > 0) {
                i += try std.unicode.utf8Encode(@intCast(u21, cell.char), buf[i..]);
            }
        }
    }

    // Never render the final newline
    const str = std.mem.trimRight(u8, buf[0..i], "\n");
    return try alloc.realloc(buf, str.len);
}

test "Screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();
    try testing.expect(s.rowsWritten() == 0);

    // Sanity check that our test helpers work
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try testing.expect(s.rowsWritten() == 3);
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }

    // Test the row iterator
    var count: usize = 0;
    var iter = s.rowIterator(.viewport);
    while (iter.next()) |row| {
        // Rows should be pointer equivalent to getRow
        const row_other = s.getRow(.{ .viewport = count });
        try testing.expectEqual(row.storage.ptr, row_other.storage.ptr);
        count += 1;
    }

    // Should go through all rows
    try testing.expectEqual(@as(usize, 3), count);

    // Should be able to easily clear screen
    {
        var it = s.rowIterator(.viewport);
        while (it.next()) |row| row.fill(.{ .char = 'A' });
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("AAAAA\nAAAAA\nAAAAA", contents);
    }
}

test "Screen: scrolling" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try testing.expect(s.viewportIsBottom());

    // Scroll down, should still be bottom
    try s.scroll(.{ .delta = 1 });
    try testing.expect(s.viewportIsBottom());

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling to the bottom does nothing
    try s.scroll(.{ .bottom = {} });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}

test "Screen: scroll down from 0" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Scrolling up does nothing, but allows it
    try s.scroll(.{ .delta = -1 });
    try testing.expect(s.viewportIsBottom());

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
}

test "Screen: scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 1);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try s.scroll(.{ .delta = 1 });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling to the bottom
    try s.scroll(.{ .bottom = {} });
    try testing.expect(s.viewportIsBottom());

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling back should make it visible again
    try s.scroll(.{ .delta = -1 });
    try testing.expect(!s.viewportIsBottom());

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Scrolling back again should do nothing
    try s.scroll(.{ .delta = -1 });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Scrolling to the bottom
    try s.scroll(.{ .bottom = {} });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling forward with no grow should do nothing
    try s.scroll(.{ .delta_no_grow = 1 });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }

    // Scrolling to the top should work
    try s.scroll(.{ .top = {} });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Should be able to easily clear active area only
    var it = s.rowIterator(.active);
    while (it.next()) |row| row.clear(.{});
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD", contents);
    }

    // Scrolling to the bottom
    try s.scroll(.{ .bottom = {} });

    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("", contents);
    }
}

test "Screen: scrollback with large delta" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 3);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH\n6IJKL");
    try testing.expect(s.viewportIsBottom());

    // Scroll to top
    try s.scroll(.{ .top = {} });
    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    // Scroll down a ton
    try s.scroll(.{ .delta = 5 });
    try testing.expect(s.viewportIsBottom());
    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("3IJKL\n4ABCD\n5EFGH\n6IJKL", contents);
    }
    {
        // Test our contents rotated
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("6IJKL", contents);
    }
}

test "Screen: scrollback empty" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 50);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try s.scroll(.{ .delta_no_grow = 1 });

    {
        // Test our contents
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }
}

test "Screen: history region with no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 1, 5, 0);
    defer s.deinit();

    // Write a bunch that WOULD invoke scrollback if exists
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }

    // Verify no scrollback
    var it = s.rowIterator(.history);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    try testing.expect(count == 0);
}

test "Screen: history region with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 1, 5, 2);
    defer s.deinit();

    // Write a bunch that WOULD invoke scrollback if exists
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL";
        try testing.expectEqualStrings(expected, contents);
    }
    {
        // Test our contents
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings("1ABCD\n2EFGH\n3IJKL", contents);
    }

    {
        var contents = try s.testString(alloc, .history);
        defer alloc.free(contents);
        const expected = "1ABCD\n2EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}
test "Screen: row copy" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    // Copy
    try s.scroll(.{ .delta = 1 });
    s.copyRow(.{ .active = 2 }, .{ .active = 0 });

    // Test our contents
    var contents = try s.testString(alloc, .viewport);
    defer alloc.free(contents);
    try testing.expectEqualStrings("2EFGH\n3IJKL\n2EFGH", contents);
}

test "Screen: selectionString" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 1 },
            .end = .{ .x = 2, .y = 2 },
        });
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJ";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString soft wrap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH3IJKL";
    try s.testWriteString(str);

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 1 },
            .end = .{ .x = 2, .y = 2 },
        });
        defer alloc.free(contents);
        const expected = "2EFGH3IJ";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString wrap around" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");
    try testing.expect(s.viewportIsBottom());

    // Scroll down, should still be bottom, but should wrap because
    // we're out of space.
    try s.scroll(.{ .delta = 1 });
    try testing.expect(s.viewportIsBottom());
    try s.testWriteString("1ABCD\n2EFGH\n3IJKL");

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 1 },
            .end = .{ .x = 2, .y = 2 },
        });
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJ";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString wide char" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1A⚡";
    try s.testWriteString(str);

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 3, .y = 0 },
        });
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 2, .y = 0 },
        });
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 3, .y = 0 },
            .end = .{ .x = 3, .y = 0 },
        });
        defer alloc.free(contents);
        const expected = "⚡";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: selectionString wide char with header" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABC⚡";
    try s.testWriteString(str);

    {
        var contents = try s.selectionString(alloc, .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 4, .y = 0 },
        });
        defer alloc.free(contents);
        const expected = str;
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize (no reflow) more rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resizeWithoutReflow(10, 5);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize (no reflow) less rows" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resizeWithoutReflow(2, 5);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings("2EFGH\n3IJKL", contents);
    }
}

test "Screen: resize (no reflow) more cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resizeWithoutReflow(3, 10);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize (no reflow) less cols" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    try s.resizeWithoutReflow(3, 4);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "1ABC\n2EFG\n3IJK";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize (no reflow) more rows with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 2);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resizeWithoutReflow(10, 5);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize (no reflow) less rows with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 2);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    try s.resizeWithoutReflow(2, 5);

    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        const expected = "2EFGH\n3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }
}

test "Screen: resize (no reflow) empty screen" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 5, 5, 0);
    defer s.deinit();
    try testing.expect(s.rowsWritten() == 0);
    try testing.expectEqual(@as(usize, 5), s.rowsCapacity());

    try s.resizeWithoutReflow(10, 10);
    try testing.expect(s.rowsWritten() == 0);

    // This is the primary test for this test, we want to ensure we
    // always have at least enough capacity for our rows.
    try testing.expectEqual(@as(usize, 10), s.rowsCapacity());
}

test "Screen: resize more rows no scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    const cursor = s.cursor;
    try s.resize(10, 5);

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize more rows with empty scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 10);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    const cursor = s.cursor;
    try s.resize(10, 5);

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize more rows with populated scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 5);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL\n4ABCD\n5EFGH";
    try s.testWriteString(str);
    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        const expected = "3IJKL\n4ABCD\n5EFGH";
        try testing.expectEqualStrings(expected, contents);
    }

    // Set our cursor to be on the "4"
    s.cursor.x = 0;
    s.cursor.y = 1;
    try testing.expectEqual(@as(u32, '4'), s.getCell(.active, s.cursor.y, s.cursor.x).char);

    // Resize
    try s.resize(10, 5);

    // Cursor should still be on the "4"
    try testing.expectEqual(@as(u32, '4'), s.getCell(.active, s.cursor.y, s.cursor.x).char);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}

test "Screen: resize more cols no reflow" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var s = try init(alloc, 3, 5, 0);
    defer s.deinit();
    const str = "1ABCD\n2EFGH\n3IJKL";
    try s.testWriteString(str);
    const cursor = s.cursor;
    try s.resize(3, 10);

    // Cursor should not move
    try testing.expectEqual(cursor, s.cursor);

    {
        var contents = try s.testString(alloc, .viewport);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
    {
        var contents = try s.testString(alloc, .screen);
        defer alloc.free(contents);
        try testing.expectEqualStrings(str, contents);
    }
}
