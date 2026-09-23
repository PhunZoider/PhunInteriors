# Supported vehicles

Which vehicle opens onto which room. Generated from `Docs/pi-assigned.csv` and
`Docs/pi-vehicles.csv`, the same files `scripts/gendefaults.pl` builds the
registry from; regenerate this page when they change.

Script names drop the `Base.` prefix. Vehicles from other mods are listed by
the script name that mod uses, and only get a room when that mod is installed:
a binding that names a vehicle the game does not have simply never matches.

**Floor** is the floor you can walk on, in squares. **Overflow** is the room a
vehicle is given once every slot of its own room is taken. A room with no
overflow refuses the vehicle when it is full.

A vehicle not listed here has no interior. A server admin can bind one in the
room editor ([admin.md](admin.md)), and a mod can bind its own
([modding.md](modding.md)).

| Room | Floor | Vehicles | Overflow |
|---|---|---|---|
| Ambulance Bay | 3x3 | `90fordF350ambulance` | Van - Ambulance |
| Bus | 3x9 | *none yet* |  |
| Bus - Military | 3x9 | `87fordB700military` | Bus |
| Bus - Prison | 3x9 | `87fordB700prison` | Bus |
| Bus - School | 3x9 | `87fordB700school` | Bus |
| Camper - Dasher | 2x4 | `DashRoamer` |  |
| Camper - Large | 3x9 | `Trailer54FlyingCloud22` |  |
| Camper - Medium | 3x5 | `Trailer61Bambi16` |  |
| Camper - Mini | 2x3 | `Trailer87Scamp13` |  |
| Camper - Small | 2x4 | `Trailer87Scamp16` |  |
| Container - Factory | 3x6 | `isoContainer4`, `TrailerM747lowbed` |  |
| Container - Storage | 3x6 | `isoContainer5`, `TrailerM747lowbed` |  |
| Container - Warehouse | 3x6 | `isoContainer2`, `TrailerM747lowbed` |  |
| GAGE K15 | 4x5 | `84gageV300apc`, `84gageV300fsv`, `lockMartM577` |  |
| Military Box | 4x4 | `86chevyM1010`, `86chevyM1031` |  |
| RV - Large | 3x9 | `RollingRefuge` |  |
| RV - Small | 3x5 | `WhennyagoInitiative` |  |
| RV - Spare 1 | 3x9 | *none yet* |  |
| RV - Spare 2 | 3x9 | *none yet* |  |
| Semi Trailer - Factory | 3x13 | `SemiTrailerVanCattle` | Semi Trailer - Water |
| Semi Trailer - Warehouse | 3x13 | `SemiTrailerVan`, `W900_Container` | Semi Trailer - Water |
| Semi Trailer - Water | 3x13 | `SemiTrailerVan_mil` | Semi Trailer - Warehouse |
| Step Van | 3x4 | `StepVan` | Van |
| Step Van - Beer | 3x4 | `StepVan_Genuine_Beer` | Step Van |
| Step Van - Blacksmith | 3x4 | `StepVan_Blacksmith` | Step Van |
| Step Van - Book | 3x4 | `StepVan_MobileLibrary` | Step Van |
| Step Van - Butcher | 3x4 | `StepVan_Butchers` | Step Van |
| Step Van - Carpentry | 3x4 | `StepVan_Jorgensen` | Step Van |
| Step Van - Catering | 3x4 | `StepVan_SouthEasternHosp`, `StepVanAirportCatering` | Step Van |
| Step Van - Citr8 | 3x4 | `StepVan_Citr8`, `StepVan_Zippee` | Step Van |
| Step Van - Fish | 3x4 | `StepVan_MarineBites` | Step Van |
| Step Van - Florist | 3x4 | `StepVan_Florist` | Step Van |
| Step Van - Glass | 3x4 | `StepVan_Glass` | Step Van |
| Step Van - Groceries | 3x4 | `StepVan_Cereal` | Step Van |
| Step Van - Laundry | 3x4 | `StepVan_HuangsLaundry` | Step Van |
| Step Van - Logistics | 3x4 | `StepVan_USL` | Step Van |
| Step Van - Mail | 3x4 | `StepVanMail` | Step Van |
| Step Van - Masonry | 3x4 | `StepVan_Masonry` | Step Van |
| Step Van - Mechanic | 3x4 | `StepVan_LouisvilleMotorShop`, `StepVan_Mechanic` | Step Van |
| Step Van - News | 3x4 | `StepVan_Heralds` | Step Van |
| Step Van - Paint | 3x4 | `StepVan_SouthEasternPaint` | Step Van |
| Step Van - Plants | 3x4 | `StepVan_RandisPlants` | Step Van |
| Step Van - Plonkies | 3x4 | `StepVan_Plonkies` | Step Van |
| Step Van - Propane | 3x4 | `StepVan_Propane` | Step Van |
| Step Van - Repair | 3x4 | `StepVan_CompleteRepairShop` | Step Van |
| Step Van - SWAT | 3x4 | `87fordF700swat`, `90fordF350SWAT`, `StepVan_LouisvilleSWAT` | Step Van |
| Step Van - Tailoring | 3x4 | `StepVan_SmartKut` | Step Van |
| Step Van - Whiskey | 3x4 | `StepVan_Scarlet` | Step Van |
| Tent | 2x3 | `TentBlue`, `TentBrown`, `TentGreen`, `TentYellow` |  |
| Trailer - Livestock | 3x4 | `Trailer_Horsebox`, `Trailer_Livestock` |  |
| Trailer - Medium | 3x9 | `SemiTruckBox`, `SemiTruckBox_mil` |  |
| Trailer - Military | 3x9 | `TrailerM128van`, `TrailerM129van` |  |
| Truck - Armored | 2x4 | `87fordF700bank` | Van |
| Truck - Furniture | 3x6 | `87fordF700box` | Van |
| Van | 2x3 | `Van`, `Van_BugWipers`, `Van_Locksmith`, `VanDeerValley`, `VanJonesFabrication`, `VanMetalheads`, `VanOldMill`, `VanRiversideFabrication`, `VanSeats_Valkyrie` |  |
| Van - Alcohol | 2x3 | `Van_Charlemange_Beer`, `Van_KnoxDisti` | Van |
| Van - Ambulance | 2x3 | `VanAmbulance` |  |
| Van - Art Supply | 2x3 | `Van_CraftSupplies` | Van |
| Van - Blacksmith | 2x3 | `Van_Blacksmith` | Van |
| Van - Butcher | 2x3 | *none yet* | Van |
| Van - Carpenter | 2x3 | `VanCarpenter`, `VanJohnMcCoy`, `VanMccoy`, `VanMicheles`, `VanRosewoodworking`, `VanWPCarpentry` | Van |
| Van - Comms | 2x3 | `VanKnoxCom`, `VanRadio`, `VanRadio_3N` | Van |
| Van - Construction | 2x3 | `VanBeckmans`, `VanBuilder`, `VanCoastToCoast`, `VanKerrHomes`, `VanPennSHam` | Van |
| Van - Electrical | 2x3 | `Van_LectroMax`, `Van_VoltMojo`, `VanPluggedInElectrics` | Van |
| Van - Farm | 2x3 | `VanOvoFarm` | Van |
| Van - Fossil | 2x3 | `VanFossoil` | Van |
| Van - Gardening | 2x3 | `VanGardener`, `VanGardenGods`, `VanLouisvilleLandscaping`, `VanMooreMechanics`, `VanTreyBaines` | Van |
| Van - Gas and Electric | 2x3 | `VanKnobCreekGas`, `VanUtility` | Van |
| Van - Glass | 2x3 | `Van_Glass` | Van |
| Van - Greens | 2x3 | `Van_Perfick_Potato`, `VanGreenes` | Van |
| Van - Leather | 2x3 | `Van_Leather` | Van |
| Van - Love | 2x3 | `Van_Transit`, `VanSeats_LadyDelighter`, `VanSeats_Mural`, `VanSeats_Space`, `VanSeats_Trippy` | Van |
| Van - Mail | 2x3 | `VanMail` | Van |
| Van - Masonry | 2x3 | `Van_Masonry` | Van |
| Van - Mechanic | 2x3 | `VanBrewsterHarbin`, `VanKorshunovs`, `VanMechanic`, `VanMobileMechanics`, `VanPlattAuto` | Van |
| Van - Plumbing | 2x3 | `VanUncloggers` | Van |
| Van - Police | 2x3 | *none yet* | Van |
| Van - Prison | 2x3 | `VanSeats_Prison` | Van |
| Van - Seats | 2x3 | `VanSeats`, `VanSeats_Creature`, `VanSeatsAirportShuttle` | Van |
| Van - Spiffo | 2x3 | `VanSpiffo` | Van |
| Van - Tailor | 2x3 | `Van_HeritageTailors` | Van |
| Van - VW Camper | 2x4 | `63Type2Van`, `63Type2VanApocalypse`, `63Type2VanHippie`, `63Type2VanMilitary` | Van |
| Van - Welding | 2x3 | `Van_MassGenFac`, `VanMeltingPointMetal`, `VanSchwabSheetMetal` | Van |
