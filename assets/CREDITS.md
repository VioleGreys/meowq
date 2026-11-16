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
| Города от 1000 жителей (cities1000) | названия провинций без крупного города (`tools/build_map.py --geonames`) | GeoNames, geonames.org | CC BY 4.0 — указать авторство |

Решение пользователя: допускаются общественное достояние, CC0, CC BY (с
указанием автора) и некоммерческие лицензии (NC) — но тогда игру нельзя
продавать, пока такие материалы не заменены. Отмечать NC-материалы здесь явно.
Материалы коммерческих игр не используем. Игру продавать не будем (решение
пользователя, ноябрь 2026): материалы с указанием авторства (CC BY, CC BY-SA)
и некоммерческие (NC) можно брать без ограничений — с записью сюда.
