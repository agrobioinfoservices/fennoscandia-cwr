# Clean occurrence data for distribution analysis 
# K. de Sousa 
# Inland Norway University
#..........................................
#..........................................
# Packages ####
library("data.table")
library("maptools")
library("raster")
library("rgdal")
library("dismo")
library("alphahull")
library("rgeos")
library("sf")


# extra function 
source("script/helper01_functions.R")


sessioninfo::session_info()
# write session info
capture.output(sessioninfo::session_info(),
               file = "script/session_info/03_data_cleaning.txt")

# ........................................
# ........................................
# Data ####

# gadm adm0 europe
list.files("data/gadm/europe", pattern = ".shp$")

gadm <- readOGR(dsn = "data/gadm/europe", layer = "europe")

# europe 0.10 arc-min buffer area 
b <- readOGR("data/gadm/europe", "europe_buffer_010arcmin")

# europe coast points
coast <- readOGR("data/gadm/europe", "europe_coast_points")

# europe as a whole
eur <- readOGR("data/gadm/europe", "europe")

# list of target countries
country <- fread("data/country_iso.csv")
country <- country["Europe", on = "region"]
country <- country$alpha2

# define projection
myproj <- proj4string(gadm)

#........................................
#........................................
# Read occurrence data ####

# Read genesys data
gen <- fread("data/raw/genesys_occurrences_manual_download.csv")

gen[, scientific_name := paste(genus, species)]

gen[, source := "genesys"]

gen <- gen[, .(acronym, scientific_name, lon, lat, country, source)]

plot(gen[, .(lon, lat)])

sort(table(gen$acronym))

length(table(gen$acronym))

# Read GBIF data
gbif <- fread("data/raw/gbif_occurrences.csv")

# rename the variables
names(gbif) <- c("name","scientific_name","country","lon",
               "lat","key","record","publishing_org",
               "year","gbif_id","taxa","acronym")


# remove entries older than 1950
keep <- gbif$year >= 1950 & !is.na(gbif$year)

gbif <- gbif[keep, ]

gbif[, source := "gbif"]

gbif <- gbif[, .(acronym, scientific_name, lon, lat, country, source)]

plot(gbif[, .(lon, lat)])

sort(table(gbif$acronym))

length(table(gbif$acronym))

# Check occurrences in both datasets
dt <- rbind(gen, gbif)

length(unique(dt$acronym))

table(dt$acronym)

#........................................
#........................................
# Data cleaning 1 ####

# no NAs in lon
keep <- !is.na(dt$lon)

# and no NAs in lat
keep <- !is.na(dt$lat) & keep

# apply filter
dt <- dt[keep, ]

# remove coordinates without decimals
keep <- unlist(lapply(dt$lon, .decimalplaces)) > 0

keep <- unlist(lapply(dt$lat, .decimalplaces)) > 0 & keep

dt <- dt[keep, ]

length(unique(dt$acronym))

table(dt$acronym)

#........................................
#........................................
# Spatial cleaning 1 ####
# remove points outside country borders
coord <- dt[, .(lon, lat)]
coord <- SpatialPoints(coord, proj4string = CRS(myproj))
plot(coord)

keep <- over(coord, b)

keep <- !is.na(keep[[1]])

dt <- dt[keep, ]

length(unique(dt$acronym))

table(dt$acronym)

#........................................
#........................................
# Spatial cleaning 2 ####
# put GENESYS data in a different dataset
gen <- dt[dt$source == "genesys", ]
dt <- dt[dt$source == "gbif", ]

coord <- dt[, .(lon, lat)]
coord <- SpatialPoints(coord, proj4string = CRS(myproj))

plot(gadm)
points(coord, col = "blue", pch = 20)

# revise points in the sea and correct those placed within 10 arc-min
# from the coastal border
# keep sea area in a buffer of 10 arcmin
sea <- gDifference(b, eur, byid = TRUE)
ids <- sapply(slot(sea, "polygons"), function(x) slot(x, "ID"))
ids <- data.frame(sea = "sea", row.names = ids)
sea <- SpatialPolygonsDataFrame(sea, ids)

# identify points in the sea
sea <- over(coord, sea)
sea <- !is.na(sea[[1]])

# subset coordinates in the sea
sea_coord <- dt[sea, .(lon, lat, acronym)]

sea_coord <- split(sea_coord, rownames(sea_coord))

# transform dataframes into spatial points then set the original projection
sea_buffer <- lapply(sea_coord, function(x) {
  x <- SpatialPoints(x[, .(lon, lat)], proj4string = CRS(myproj))
  # set the projection
  x <- gBuffer(x, byid = TRUE, width = 0.5)
  # return the result
  x
})

# run over coordinates and find the nearest point in the land
nearest <- list()
pb <- txtProgressBar(min = 0, max = length(sea_buffer), initial = 1) 
for(i in seq_along(sea_buffer)) {
  
  x <- over(coast, sea_buffer[[i]])
  x <- coast@coords[!is.na(x), ]

  if (nrow(x) > 0) {
    x <- SpatialPoints(x, proj4string = CRS(myproj))
    
    # the original point
    y <- sea_coord[[i]][, c("lon","lat")]
    y <- SpatialPoints(y, proj4string = CRS(myproj))
    
    # find the nearest point
    d <- pointDistance(x, y, lonlat = TRUE)
    d <- which.min(d)
    d <- x@coords[d,]
    names(d) <- c("lon","lat")
    
    nearest[[i]] <- d 
    
  } else {
    nearest[[i]] <- data.frame(lon = -999, lat = -999)
  }
  
  setTxtProgressBar(pb,i)
}

rm(x,y,d,i)

nearest <- do.call("rbind", nearest)


# replace sea points by their nearest points in the land
dt[sea, "lon"] <- nearest[,1]
dt[sea, "lat"] <- nearest[,2]

# remove possible -999 values
keep <- dt$lon != -999

dt <- dt[keep, ]

coord <- dt[, .(lon, lat)]
coord <- SpatialPoints(coord, proj4string = CRS(myproj))

plot(gadm)
points(coord, col = "blue", pch = 20)

length(unique(dt$acronym))

table(dt$acronym)

# ....................................
# ....................................
# remove points within the same grid cell
bio <- list.files("data/bioclim/", pattern = ".tif", full.names = TRUE)[1]
bio <- raster(bio)

acronym <- sort(unique(dt$acronym))

dt_coords <- data.frame()

pb <- txtProgressBar(min = 1, max = length(acronym), initial = 1) 
for (i in seq_along(acronym)) {
  
  
  k <- dt$acronym == acronym[i]
  # sampling data
  dt_i <- dt[k, ]
  
  coord <- dt_i[, .(lon, lat)]
  
  largedist <- pointDistance(coord, longlat = FALSE)
  
  largedist <- max(largedist)
  
  # make a convex hull and remove duplicated coordinates
  # in the same grid-cell
  hull <- convHull(coord, lonlat = TRUE)
  # extent convex hull
  ext_hull <- gBuffer(hull@polygons, width = 0.1 * largedist)
  crs(ext_hull) <- proj4string(eur)
  
  # define raster
  r <- raster(ext_hull)
  # set the resolution of the cells to 
  # 30 arc-sec
  res(r) <- res(bio)
  
  coord <- as.data.frame(coord)
  
  coord <- gridSample(coord, r, n = 1)
  
  coord$acronym <- acronym[i]
  
  coord$scientific_name <- dt_i$scientific_name[i]
  
  coord$source <- dt_i$source[i]
  
  dt_coords <- rbind(dt_coords, coord)
  
  setTxtProgressBar(pb,i)
}

dt_coords <- as.data.table(dt_coords)

# put genesys data back to the main dataset
gen <- gen[, !c("country")]

dt <- rbind(dt_coords, gen)

coord <- dt[, .(lon, lat)]
coord <- SpatialPoints(coord, proj4string = CRS(myproj))

plot(gadm)
points(coord, col = "blue", pch = 20)

# ......................................
# ......................................
# write outputs
# count number of points per species and add to species names
library("tidyverse")
dt %>% 
  group_by(acronym) %>%  
  count(acronym) %>% 
  mutate(keep = n > 29) %>% 
  filter(keep) ->
  keep 

keep <- dt$acronym %in% keep$acronym

dt <- dt[keep, ]

dt %>% 
  group_by(acronym, source) %>% 
  count() -> x

length(unique(dt$acronym))

table(dt$acronym)

# write file with cleaned points
write.csv(dt, "data/passport_data.csv", row.names = FALSE)

x <- dt[dt$acronym == dt$acronym[[1]] & dt$source == "genesys", ]

x %>%
  dplyr::select(lon,lat) %>%
  SpatialPoints(., proj4string = CRS(myproj)) ->
  coord

plot(eur, col = "lightgrey")
plot(coord, col = "blue", cex = 1,
     bg = "Steelblue1", pch = 21, add = TRUE)

x <- as.data.frame(x)
plot_map(x, c("lon", "lat"), add = "acronym")
