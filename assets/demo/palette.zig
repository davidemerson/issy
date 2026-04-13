const std = @import("std");

pub const Palette = struct {
    red: u8,
    green: u8,
    blue: u8,
};

pub const primary = Palette{
    .red = 255,
    .green = 0,
    .blue = 0,
};

pub const secondary = Palette{
    .red = 0,
    .green = 255,
    .blue = 0,
};

pub const tertiary = Palette{
    .red = 0,
    .green = 0,
    .blue = 255,
};
