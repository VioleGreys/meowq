# Сторонние материалы

Все материалы ниже свободны для использования; при выпуске игры перечень
нужно показать на экране «Авторы».

| Материал | Где в игре | Источник | Лицензия |
|---|---|---|---|
| Спутниковый снимок «Whole world — land and oceans» (Blue Marble) | подложка рельефа карты, `data/world1936/terrain.jpg.bin` (перепроецирован `tools/build_terrain.py`) | NASA / Goddard Space Flight Center, Visible Earth; копия на Викискладе | общественное достояние |
| Границы, реки, озёра, города, акватории | карта (`tools/build_map.py`) | Natural Earth | общественное достояние |
| Цвет природных зон NE1_HR_LC (Tom Patterson) | цвет местности карты, `assets/map/colormap.jpg` (`tools/build_map_art.py`) | Natural Earth, naturalearthdata.com | общественное достояние |
| Рельеф суши и дна ETOPO1 Ice Surface | свет рельефа (`assets/map/normal.png`), высоты суши для гор (`assets/map/elev_*.png`, `tools/etopo.py`; канал r `relief.png.bin`), местность горы и холмы (`build_map.py --etopo`), глубины моря, `tools/build_map_art.py` | NOAA National Centers for Environmental Information | общественное достояние |
| Климатическая карта Кёппена — Гейгера 1901–1930 гг., 1 км (H. E. Beck и др., «High-resolution (1 km) Köppen-Geiger maps for 1901–2099 based on constrained CMIP6 projections», Scientific Data, 2023) | местность «пустыня» и пески/степи на карте (канал a `relief.png.bin`), `tools/aridity.py`, `build_map.py --kg` | figshare, doi:10.6084/m9.figshare.21789074 (gloh2o.org/koppen) | CC BY 4.0 (указать авторов) |
| Global Lakes and Wetlands Database 2.0 (B. Lehner и др., «Mapping the world's inland surface waters: an upgrade to the Global Lakes and Wetlands Database (GLWD v2)», Earth System Science Data, 2025) | болота на карте и местность «болото» (канал g `cover.png.bin`, `tools/wetlands.py`, `tools/build_cover.py`, `build_map.py --glwd`) | figshare, doi:10.6084/m9.figshare.28519994 (hydrosheds.org) | CC BY 4.0 (указать авторов) |
| Global Forest Change 2000–2023, treecover2000 (M. C. Hansen и др., «High-Resolution Global Maps of 21st-Century Forest Cover Change», Science, 2013; University of Maryland) | леса на карте и местность «лес» (канал r `cover.png.bin`, `tools/forest.py`, `build_map.py --forest`) | glad.earthengine.app/view/global-forest-change | CC BY 4.0 (указать авторов) |
| 3D-модели: Buildings, Simple Buildings, Farm Buildings, Medieval Village Pack, Ultimate Nature (Quaternius, quaternius.com) | постройки и деревья на карте вблизи — атлас `data/world1936/sprites.png.bin` (`tools/render_sprites.gd`, список `tools/sprites.json`) | quaternius.com, opengameart.org | CC0 |
| 3D-модели: City Kit Industrial (Kenney, kenney.nl) | заводы на карте (тот же атлас, перекрашены в кирпич) | opengameart.org | CC0 |
| 3D-модели домов Франции и Бельгии (≈60 моделей: Troyes, Nivelles, Mons, Bordeaux, Dijon и др.), Lost_Gecko, sketchfab.com/Lost_Gecko | дома городов Запада (атлас `sprites.png.bin`, `tools/sprites.json`) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Germanic Villiage», novusod, https://sketchfab.com/3d-models/germanic-villiage-aa888d2db9d3443993e0a7695d267aac | деревня (Германия) (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Traditional Russian Cabin (Izba)», Mad_Lobster_Workshop, https://sketchfab.com/3d-models/traditional-russian-cabin-izba-63f35b42bf3f4b2cb8b15262d5d3b991 | изба (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Russian Izba - Low-Poly 3D Game Asset», SergeyLubivui, https://sketchfab.com/3d-models/russian-izba-low-poly-3d-game-asset-b9b78aa1cf1c495b8f223feecebd661c | изба (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Industrial Buildings Set - Low poly models», Daniel Zhabotinsky, https://sketchfab.com/3d-models/industrial-buildings-set-low-poly-models-e0b0d0342be24e6c923319991a2a4d3d | заводские цеха (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Industrial Smoke Stacks», FrodoUndead, https://sketchfab.com/3d-models/industrial-smoke-stacks-ffaf6bfbd8b84eb985dee2a35ba79440 | трубы (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Low-poly Modular Building Tenement House», Orzechu, https://sketchfab.com/3d-models/low-poly-modular-building-tenement-house-c579c4f421f94574b98e7eba7cd5f2a8 | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Old russian house», akiprensky, https://sketchfab.com/3d-models/old-russian-house-857186ff54fd45ae85618c02ddd762c0 | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Russian village house», Ivan-Kanaev, https://sketchfab.com/3d-models/russian-village-house-46e4bc34fe794f398f7107a6791698db | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Old Russian House», Vodum Games, https://sketchfab.com/3d-models/old-russian-house-5545835e67164fb49900a9aee589feee | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Дом Деревня СССР СНГ / Village House USSR CIS», chewbacca13351, https://sketchfab.com/3d-models/village-house-ussr-cis-8223612f374f4b03ac3feffacbaab1e1 | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Low-poly Brick House», Vitalii.Sandula, https://sketchfab.com/3d-models/low-poly-brick-house-ea82ea891829493aadeea889cd473e89 | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Rural Brick House with Barn and Chicken Coop», Vitalii.Sandula, https://sketchfab.com/3d-models/rural-brick-house-with-barn-and-chicken-coop-4708a315b2ff42d08c55c6f5d5ca7c21 | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Brick house», FrodaJan, https://sketchfab.com/3d-models/brick-house-6eb02721fa574c249184779c1242ae07 | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Old brick house», Kiiba, https://sketchfab.com/3d-models/old-brick-house-cb92673947714bed977ef65cc241fb6f | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «XX century italian house», yarogor, https://sketchfab.com/3d-models/xx-century-italian-house-4c0c8c1244b84e3b97288867f47f5f04 | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Old Cottage», LukaszKkkk, https://sketchfab.com/3d-models/old-cottage-ceff67ca56cd47a6b5890f74325ddd7f | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Thatched rural houses», massive-graphisme, https://sketchfab.com/3d-models/thatched-rural-houses-2c860d668b0f44689fe4de0cb4dd4af4 | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Old barrack from DayZ», Shotkey, https://sketchfab.com/3d-models/old-barrack-from-dayz-9419706c98c94dfb83d7d3e19f7a6a37 | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Old House - Building Realistic Asset Low-poly», DrFeelgood, https://sketchfab.com/3d-models/old-house-building-realistic-asset-low-poly-66d8e53292cc4c52a4c01e09d334b02b | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Old House 1», Оrрндп ЯТG, https://sketchfab.com/3d-models/old-house-1-2c7338b6abd442e99222b6e18998e36c | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Residences of Rothenburg ob der Tauber», Shotkey, https://sketchfab.com/3d-models/residences-of-rothenburg-ob-der-tauber-af81933914b14dcbbb39bd8a0bbafaaf | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Low Poly Portuguese Village House 3», AlexFerrart3D, https://sketchfab.com/3d-models/low-poly-portuguese-village-house-3-994e1e752ac04d02a8918763fbaf3651 | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Low Poly Portuguese Village House 1», AlexFerrart3D, https://sketchfab.com/3d-models/low-poly-portuguese-village-house-1-28262619cb304134830b4ebeafdf090b | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «German styled house», Christoffer Eriksson, https://sketchfab.com/3d-models/german-styled-house-80f8fca27d36466590f7d4d166131331 | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Дом Сергеева из д. Логморучей», kizhi, https://sketchfab.com/3d-models/24ff3c25751a426194388312d89ed3e9 | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| 3D-модель «Дом Беляева из д. Кубовская», kizhi, https://sketchfab.com/3d-models/a5171fb17f2043fd871f6c24926880b1 | дома по регионам (атлас построек) | Sketchfab | CC BY 4.0 (указать автора) |
| Текстуры PavingStones070, Ground048, Bricks060 (ambientCG, Lennart Demes) | брусчатка улиц, грунт, камень мостов и подложки города (`road_tex.png.bin`) | ambientcg.com | CC0 |
| Текстуры Grass004, Rock030, Ground054, Snow006 | фактура местности вблизи, `data/world1936/detail.png.bin` (`tools/build_detail.py`) | ambientCG.com | CC0 |
| Шрифт Oswald | заголовки, кнопки, подписи стран | Vernon Adams и др., Google Fonts | SIL Open Font License 1.1 (`fonts/OFL-Oswald.txt`) |
| Иконки родов войск, флота, авиации, меню (21 шт., список — `tools/build_icons.py`) | фишки на карте, боковое меню, `assets/icons/icons.json` | game-icons.net (авторы — Lorc, Delapouite и др.), через npm-пакет @iconify-json/game-icons | CC BY 3.0 — указать авторов на экране «Авторы» |
| Звуки нажатия кнопок (`assets/sounds/`) | интерфейс | свои, синтезированы `tools/build_sounds.py` | наши |
| Картон, кожа, износ (пятна, царапины, ржавчина) | интерфейс «Досье», `assets/ui/` | ambientCG.com: Cardboard002, Leather026, SurfaceImperfections001/013, Scratches003/005, Rust009 | CC0 |
| Лист старой бумаги | листы окон, кнопки, наклейки | OpenGameArt «horror game note page background old paper» | CC0 |
| Мятая бумага | помятые листы (события, анкеты) | OpenGameArt «Damaged papers — four sorts», автор hjm | CC BY — указать автора |
| Скрепка | интерфейс | OpenClipart 333299 | общественное достояние |
| 3D-модель «Clipboard» (рендер сверху) | планшет событий | Poly Haven, автор ProgrammerOnCoffee | CC0 |
| Шрифт IBM Plex Mono | машинописный текст интерфейса | IBM, Google Fonts | SIL OFL 1.1 (`fonts/OFL-IBMPlexMono.txt`) |
| Портреты лидеров (`assets/portraits/`, список и источники — `assets/art_credits.json`) | карточки стран, папки | Википедия/Викисклад, Библиотека Конгресса США, Europeana, поиск картинок | у части — ВРЕМЕННО, лицензия не проверена (`"temporary": true`) — заменить до выпуска |
| Шрифты PT Sans, PT Serif | текст интерфейса, события | ParaType, Google Fonts | SIL Open Font License 1.1 (`fonts/OFL-PTSans.txt`, `fonts/OFL-PTSerif.txt`) |
| Административные районы (ADM2, где нет — ADM1) 201 страны | границы провинций карты (`tools/fetch_adm2.py`, `tools/provinces8k.py`) | geoBoundaries (gbOpen), Runfola D. et al. (2020) «geoBoundaries: A global database of political administrative boundaries», PLoS ONE 15(4): e0231866; источники по странам — в ответе API | ODbL 1.0 / CC BY 4.0 и др. открытые (по стране) — указать авторство |
| Города от 1000 жителей (cities1000) | названия провинций без крупного города (`tools/build_map.py --geonames`), пятна городов 1936 г. на карте (канал b `cover.png.bin`, `tools/build_cover.py`) | GeoNames, geonames.org | CC BY 4.0 — указать авторство |

Решение пользователя: допускаются общественное достояние, CC0, CC BY (с
указанием автора) и некоммерческие лицензии (NC) — но тогда игру нельзя
продавать, пока такие материалы не заменены. Отмечать NC-материалы здесь явно.
Материалы коммерческих игр не используем. Игру продавать не будем (решение
пользователя, ноябрь 2026): материалы с указанием авторства (CC BY, CC BY-SA)
и некоммерческие (NC) можно брать без ограничений — с записью сюда.
