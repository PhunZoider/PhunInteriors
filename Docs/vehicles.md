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
room editor ([remapping.md](remapping.md)), and a vehicle mod can bind its own
([vehicle-mods.md](vehicle-mods.md)).

| Room | Floor | Vehicles | Overflow |
|---|---|---|---|
| Ambulance Bay | 3x3 | `90fordF350ambulance`, `fr_fo_econoline_86_ambulance`, `fr_fo_f350_ambulance_80`, `pzkF350BoxAmbulance`, `pzkF350BoxCUCV`, `pzkVanBoxAmbulance` | Van - Ambulance |
| Bus | 3x9 | *none yet* |  |
| Bus - Military | 3x9 | `87fordB700military`, `pzkFranklinTruckBusArmy` | Bus |
| Bus - Plain | 3x9 | `fr_gm_newlook_70_35foot`, `pzkFranklinTruckBusAirport`, `pzkGmNewLookBus`, `pzkTransitBus` | Bus |
| Bus - Prison | 3x9 | `87fordB700prison`, `fr_fo_b700_prisonlong`, `pzkFranklinTruckBusPrison` | Bus |
| Bus - School | 3x9 | `87fordB700school`, `fr_fo_b700_schoollong`, `pzkFranklinTruckBus` | Bus |
| Bus - School Small | 3x5 | `fr_fo_b700_schoolshort`, `pzkStepVanB30BusChurchWoodcrafterMiddle`, `pzkStepVanB30BusWoodcrafterMiddle` | Bus - School |
| Camper - Dasher | 2x4 | `DashRoamer` |  |
| Camper - Large | 3x9 | `Trailer54FlyingCloud22` |  |
| Camper - Medium | 3x5 | `Trailer61Airflyte`, `Trailer61Astrodome`, `Trailer61Bambi16`, `Trailer_fr_camper_scamp` |  |
| Camper - Mini | 2x3 | `Trailer87Scamp13` |  |
| Camper - Small | 2x4 | `pzkTrailerCamping`, `Trailer87Scamp16` |  |
| Container - Factory | 3x6 | `isoContainer4`, `TrailerM747lowbed` |  |
| Container - Storage | 3x6 | `fr_fo_f700_90_boxmed`, `isoContainer5`, `TrailerM747lowbed` |  |
| Container - Warehouse | 3x6 | `isoContainer2`, `TrailerM747lowbed` |  |
| GAGE KI5 | 4x5 | `84gageV300apc`, `84gageV300fsv`, `lockMartM577`, `pzkCadillacGageRangerArmy`, `pzkLAV300`, `pzkM706` |  |
| Military Box | 4x4 | `86chevyM1010`, `86chevyM1031` |  |
| RV - Class A | 3x9 | `FleetwoodBounder86`, `pzkBounder86` |  |
| RV - Large | 3x9 | `fr_fl_bounder_86`, `pzkChieftain73`, `RollingRefuge` |  |
| RV - Small | 3x5 | `fr_fo_econoline_rv_86`, `pzkFranklinTruckRV`, `WhennyagoInitiative` |  |
| RV - Spare 2 | 3x9 | `pzkChevalierP6SFema` |  |
| Semi Trailer - Factory | 3x13 | `pzkTrailerRegularPop`, `pzkTrailerRegularValutech`, `SemiTrailerVanCattle` | Semi Trailer - Water |
| Semi Trailer - Warehouse | 3x13 | `pzkTrailerRegularContainer`, `pzkTrailerRegularCourtains`, `pzkTrailerRegularCourtainsBandit`, `pzkTrailerRegularCourtainsKnight`, `pzkTrailerRegularCourtainsWhite`, `pzkTrailerRegularFedLog`, `pzkTrailerRegularGigamart`, `pzkTrailerRegularLivestock`, `pzkTrailerRegularLivestock2`, `pzkTrailerRegularPharmahung`, `pzkTrailerRegularSpiffo`, `pzkTrailerRegularUStoreIt`, `SemiTrailerVan`, `Trailer_fr_semi_container`, `Trailer_fr_semi_van`, `W900_Container` | Semi Trailer - Water |
| Semi Trailer - Water | 3x13 | `SemiTrailerVan_mil` | Semi Trailer - Warehouse |
| Step Van | 3x4 | `85chevyStepVan`, `fr_ch_stepvan_80`, `pzkStepVanB30`, `pzkStepVanB30Christmas`, `pzkStepVanB30Rail`, `StepVan`, `TrailerKI5cargoLarge` | Van |
| Step Van - Beer | 3x4 | `85chevyStepVanGenuine`, `StepVan_Genuine_Beer` | Step Van |
| Step Van - Blacksmith | 3x4 | `85chevyStepVanBlacksmith`, `StepVan_Blacksmith` | Step Van |
| Step Van - Book | 3x4 | `85chevyStepVanLibrary`, `StepVan_MobileLibrary` | Step Van |
| Step Van - Butcher | 3x4 | `85chevyStepVanButchers`, `StepVan_Butchers` | Step Van |
| Step Van - Carpentry | 3x4 | `85chevyStepVanJorgensen`, `StepVan_Jorgensen` | Step Van |
| Step Van - Catering | 3x4 | `85chevyStepVanLvAirportCatering`, `85chevyStepVanSeHospitality`, `pzkStepVanCoffe`, `pzkStepVanHotDog`, `pzkStepVanIceCream`, `pzkStepVanPierogi`, `pzkStepVanPizza`, `pzkStepVanTacoVan`, `StepVan_SouthEasternHosp`, `StepVanAirportCatering` | Step Van |
| Step Van - Citr8 | 3x4 | `85chevyStepVanCitrusWave`, `85chevyStepVanZipeeMarket`, `StepVan_Citr8`, `StepVan_Zippee` | Step Van |
| Step Van - Fish | 3x4 | `85chevyStepVanMarineBites`, `pzkStepVanCatfish`, `StepVan_MarineBites` | Step Van |
| Step Van - Florist | 3x4 | `85chevyStepVanFlorist`, `StepVan_Florist` | Step Van |
| Step Van - Glass | 3x4 | `85chevyStepVanTimelessGlass`, `StepVan_Glass` | Step Van |
| Step Van - Groceries | 3x4 | `85chevyStepVanSunBallz`, `pzkStepVanMilk`, `StepVan_Cereal` | Step Van |
| Step Van - Laundry | 3x4 | `85chevyStepVanMrHuangsLaundry`, `StepVan_HuangsLaundry` | Step Van |
| Step Van - Logistics | 3x4 | `85chevyStepVanUsLogistics`, `pzkStepVanFedLog`, `pzkStepVanUPZ`, `StepVan_USL` | Step Van |
| Step Van - Mail | 3x4 | `85chevyStepVanPostal`, `pzkGrummanLLVMail`, `StepVanMail` | Step Van |
| Step Van - Masonry | 3x4 | `85chevyStepVanMasonry`, `StepVan_Masonry` | Step Van |
| Step Van - Mechanic | 3x4 | `85chevyStepVanLvMotorshop`, `StepVan_LouisvilleMotorShop`, `StepVan_Mechanic` | Step Van |
| Step Van - News | 3x4 | `85chevyStepVanHerald`, `StepVan_Heralds` | Step Van |
| Step Van - Paint | 3x4 | `85chevyStepVanSePaintingServices`, `StepVan_SouthEasternPaint` | Step Van |
| Step Van - Plants | 3x4 | `85chevyStepVanRandys`, `StepVan_RandisPlants` | Step Van |
| Step Van - Plonkies | 3x4 | `85chevyStepVanDelirosPlonkies`, `StepVan_Plonkies` | Step Van |
| Step Van - Propane | 3x4 | `85chevyStepVanPropane`, `StepVan_Propane` | Step Van |
| Step Van - Repair | 3x4 | `85chevyStepVanTheCompleteRepair`, `StepVan_CompleteRepairShop` | Step Van |
| Step Van - SWAT | 3x4 | `85chevyStepVanSWAT`, `87fordF700swat`, `90fordF350SWAT`, `fr_ch_stepvan_80_police`, `pzkCadillacGageRangerPolice`, `pzkF350BoxSwat`, `pzkFranklinSwatTruckLouisvilleSWAT`, `pzkGMCTopkickSwat`, `pzkStepVanSwatLouisvilleSWAT`, `pzkVanBoxSwat`, `StepVan_LouisvilleSWAT` | Step Van |
| Step Van - Tailoring | 3x4 | `85chevyStepVanSmartCut`, `StepVan_SmartKut` | Step Van |
| Step Van - Whiskey | 3x4 | `85chevyStepVanScarletOak`, `StepVan_Scarlet` | Step Van |
| Tent | 2x3 | `TentBlue`, `TentBrown`, `TentGreen`, `TentYellow` |  |
| Trailer - Livestock | 3x4 | `pzkTrailerHorseBox`, `Trailer_Horsebox`, `Trailer_Livestock`, `TrailerKI5livestock` |  |
| Trailer - Medium | 3x9 | `pzkTrailerBoxDual`, `pzkTrailerBoxPoliceDual`, `SemiTruckBox`, `SemiTruckBox_mil` |  |
| Trailer - Military | 3x9 | `TrailerM128van`, `TrailerM129van` |  |
| Trailer - Moving Med | 3x6 | `Trailer_fr_moving_large` |  |
| Trailer - Moving Small | 3x3 | `fr_do_ram_90_moving`, `pzkF350BoxUmoveit`, `pzkVanBox`, `Trailer_fr_moving_medium` |  |
| Truck - Armored | 2x4 | `87fordF700bank`, `pzkFranklinBankTruck` | Van |
| Truck - Furniture | 3x6 | `87fordF700box`, `fr_fo_f700_90_boxlarge`, `fr_is_nrr_93_boxmed`, `pzkFranklinTruckBox`, `pzkFranklinTruckBoxLectromax`, `pzkTruckD70Box`, `pzkTruckD70Box2` | Van |
| Truck - Sleeper Cab | 2x3 | `fr_pe_359_82_long`, `fr_pe_359_82_med`, `SemiTruck` |  |
| Van | 2x3 | `83gmcG1500aTeam`, `83gmcG1500lwb`, `fr_ch_astro_92`, `fr_fo_econoline_86`, `pzkChevalierVan70`, `pzkCVan`, `pzkCVan2Rail`, `pzkCVan3`, `pzkCVan3Rail`, `pzkCVanCargo`, `pzkCVanCargo3`, `pzkCVanRail`, `pzkDashVan70`, `pzkDashVan70Riddle`, `pzkDVan`, `pzkDVan2`, `pzkDVan3`, `pzkDVanCargo`, `pzkDVanCargo2`, `pzkDVanCargo3`, `pzkFranklinVan70`, `pzkFVan`, `pzkFVanCargo`, `pzkFVanKendo`, `pzkVanMcCoy`, `TrailerKI5cargoMedium`, `Van`, `Van_BugWipers`, `Van_Locksmith`, `VanDeerValley`, `VanJonesFabrication`, `VanMetalheads`, `VanOldMill`, `VanRiversideFabrication`, `VanSeats_Valkyrie` |  |
| Van - Alcohol | 2x3 | `Van_Charlemange_Beer`, `Van_KnoxDisti` | Van |
| Van - Ambulance | 2x3 | `pzkVanilaVanAmbulance`, `VanAmbulance` |  |
| Van - Art Supply | 2x3 | `Van_CraftSupplies` | Van |
| Van - Blacksmith | 2x3 | `Van_Blacksmith` | Van |
| Van - Butcher | 2x3 | *none yet* | Van |
| Van - Carpenter | 2x3 | `VanCarpenter`, `VanJohnMcCoy`, `VanMccoy`, `VanMicheles`, `VanRosewoodworking`, `VanWPCarpentry` | Van |
| Van - Comms | 2x3 | `VanKnoxCom`, `VanRadio`, `VanRadio_3N` | Van |
| Van - Construction | 2x3 | `pzkVanPublicWorks`, `VanBeckmans`, `VanBuilder`, `VanCoastToCoast`, `VanKerrHomes`, `VanPennSHam` | Van |
| Van - Electrical | 2x3 | `Van_LectroMax`, `Van_VoltMojo`, `VanPluggedInElectrics` | Van |
| Van - Farm | 2x3 | `VanOvoFarm` | Van |
| Van - Florist | 2x3 | `fr_fo_econoline_86_florist` | Van |
| Van - Fossil | 2x3 | `VanFossoil` | Van |
| Van - Gardening | 2x3 | `VanGardener`, `VanGardenGods`, `VanLouisvilleLandscaping`, `VanMooreMechanics`, `VanTreyBaines` | Van |
| Van - Gas and Electric | 2x3 | `VanKnobCreekGas`, `VanUtility` | Van |
| Van - Glass | 2x3 | `Van_Glass` | Van |
| Van - Greens | 2x3 | `pzkVanGigamart`, `Van_Perfick_Potato`, `VanGreenes` | Van |
| Van - Leather | 2x3 | `Van_Leather` | Van |
| Van - Love | 2x3 | `Van_Transit`, `VanSeats_LadyDelighter`, `VanSeats_Mural`, `VanSeats_Space`, `VanSeats_Trippy` | Van |
| Van - Mail | 2x3 | `fr_gr_llv_89`, `VanMail` | Van |
| Van - Masonry | 2x3 | `Van_Masonry` | Van |
| Van - Mechanic | 2x3 | `VanBrewsterHarbin`, `VanKorshunovs`, `VanMechanic`, `VanMobileMechanics`, `VanPlattAuto` | Van |
| Van - Plumbing | 2x3 | `VanUncloggers` | Van |
| Van - Police | 2x3 | `pzkVanPoliceLouisvillePD`, `pzkVanPoliceMeadeSheriff`, `pzkVanPoliceWestPoint` | Van |
| Van - Prison | 2x3 | `VanSeats_Prison` | Van |
| Van - Seats | 2x3 | `pzkCVan6Seats`, `pzkCVan6Seats3`, `pzkCVanMultivan`, `pzkCVanMultivan3`, `pzkDVan6Seats`, `pzkDVan6Seats2`, `pzkDVan6Seats3`, `pzkDVanMultivan`, `pzkDVanMultivan2`, `pzkDVanMultivan3`, `pzkFVan6Seats`, `pzkFVanMultivan`, `pzkVanMultivan`, `pzkVanMultivanPayday`, `pzkVanSeatsTaxi`, `pzkVanZSquad`, `VanSeats`, `VanSeats_Creature`, `VanSeatsAirportShuttle` | Van |
| Van - Spiffo | 2x3 | `pzkDVan2Spiffo`, `pzkDVan3Spiffo`, `pzkDVanSpiffo`, `pzkFVanSpiffo`, `VanSpiffo` | Van |
| Van - Tailor | 2x3 | `Van_HeritageTailors` | Van |
| Van - VW Camper | 2x4 | `63Type2Van`, `63Type2VanApocalypse`, `63Type2VanHippie`, `63Type2VanMilitary`, `pzkVanCamper` | Van |
| Van - Welding | 2x3 | `Van_MassGenFac`, `VanMeltingPointMetal`, `VanSchwabSheetMetal` | Van |
