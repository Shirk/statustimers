## statustimers custom theme format

statustimers support the use of custom icon themes matching the following specification:

- one folder per theme
- one BMP file per status icon
- icon size must be 32x32
- transparency is supported

A sample theme called 'kupo' would look like this:

themes/
 +-- kupo/
      +-- 0.bmp   -- fallback for missing icons (optional)
      +-- 1.bmp   -- icon for status ID 1
      +-- 2.bmp   -- icon for status ID 2
      ...
      +-- 639.bmp -- icon for status ID 639

This theme would be activated by setting the 'theme' parameter in statustimers.ini to 'kupo':

[icons]
theme = kupo

