-- Two rectangles, not one, and that is a hard engine limit rather than taste.
-- IsoMetaGrid.registerZone refuses any zone wider or taller than 1202 -- it
-- logs `not adding suspicious zone` and returns without calling addZone -- so
-- the single 1280 x 1024 rectangle covering the whole block was dropped on
-- every load and every room sat on the mains. Nothing in the mod can see that;
-- the only evidence is one line in the console and isNoPower reading 0.
--
-- 768 + 512 splits on a cell boundary at 23040 (cells 87..89, then 90..91).
-- Zone.contains is half open -- x >= zone.x and x < zone.x + width -- so the
-- two tile exactly, with no gap and no overlap.
objects = {
  { name = "Waterless", type = "NoPowerOrWater", x = 22272, y = 11776, z = 0, width = 768, height = 1024 },
  { name = "Waterless", type = "NoPowerOrWater", x = 23040, y = 11776, z = 0, width = 512, height = 1024 }
}
