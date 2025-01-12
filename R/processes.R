#' cube processes openEO standards mapped to gdalcubes processes
#'
#' @include Process-class.R
#' @import gdalcubes
#' @import rstac
#' @import useful
#' @import sf
NULL

#' schema_format
#' @description format for the schema
#'
#' @param type data type
#' @param subtype subtype of the data
#'
#' @return list with type and subtype(optional)
#' @export
schema_format = function(type, subtype = NULL, items = NULL) {
  schema = list()
  schema = append(schema,list(type=type))

  if (!is.null(subtype) && !is.na(subtype)) {
    schema = append(schema, list(subtype = subtype))
  }
  if (!is.null(items) && !is.na(items)) {
    schema = append(schema, list(items = items))
  }
  return(schema)
}


#' datacube_schema
#' @description Return a list with datacube description and schema
#'
#' @return datacube list
datacube_schema = function() {
  info = list(
    description = "A data cube for further processing",
    schema = list(type = "object", subtype = "raster-cube")
  )
  return(info)
}

#' return object for the processes
eo_datacube = datacube_schema()


#' load collection
load_collection = Process$new(
  id = "load_collection",
  description = "Loads a collection from the current back-end by its id and returns it as processable data cube",
  categories = as.array("cubes", "import"),
  summary = "Load a collection",
  parameters = list(
    Parameter$new(
      name = "id",
      description = "The collection id",
      schema = list(
        type = "string",
        subtype = "collection-id")
    ),
    Parameter$new(
      name = "spatial_extent",
      description = "Limits the data to load from the collection to the specified bounding box",
      schema = list(
        list(
          title = "Bounding box",
          type = "object",
          subtype = "bounding-box",
          properties = list(
            east = list(
              description = "East (upper right corner, coordinate axis 1).",
              type = "number"),
            west = list(
              description = "West lower left corner, coordinate axis 1).",
              type = "number"),
            north = list(
              description = "North (upper right corner, coordinate axis 2).",
              type = "number"),
            south = list(
              description = "South (lower left corner, coordinate axis 2).",
              type = "number")
          ),
        required = c("east", "west", "south", "north")
      ),
      list(
        title = "GeoJson",
        type = "object",
        subtype = "geojson"
      ),
      list(
        title = "No filter",
        description = "Don't filter spatially. All data is included in the data cube.",
        type = "null"
      )
     )
    ),
    Parameter$new(
      name = "temporal_extent",
      description = "Limits the data to load from the collection to the specified left-closed temporal interval.",
      schema = list(
        type = "array",
        subtype = "temporal-interval")
    ),
    Parameter$new(
      name = "bands",
      description = "Only adds the specified bands into the data cube so that bands that don't match the list of band names are not available.",
      schema = list(
        type = "array"),
      optional = TRUE
    ),
    ### Additional variables for flexibility due to gdalcubes
    Parameter$new(
      name = "pixels_size",
      description = "size of pixels in x-direction(longitude / easting) and y-direction (latitude / northing). Default is 300",
      schema = list(
        type = "number"),
      optional = TRUE
    ),
    Parameter$new(
      name = "time_aggregation",
      description = "size of pixels in time-direction, expressed as ISO8601 period string (only 1 number and unit is allowed) such as \"P16D\".Default is monthly i.e. \"P1M\".",
      schema = list(
        type = "string",
        subtype = "duration"),
      optional = TRUE
    ),
    Parameter$new(
      name = "crs",
      description = "Coordinate Reference System, default = 4326",
      schema = list(
        type = "number",
        subtype = "epsg-code"),
      optional = TRUE
    )

  ),
  returns = eo_datacube,
  operation = function(id, spatial_extent, temporal_extent, bands = NULL, pixels_size = 300,time_aggregation = "P1M",
                       crs = 4326, job) {
     # Temporal extent preprocess
    t0 = temporal_extent[[1]]
    t1 = temporal_extent[[2]]
    duration = c(t0, t1)
    time_range = paste(duration, collapse="/")
    message("....After Temporal extent")

    # spatial extent for cube view
    xmin = as.numeric(spatial_extent$west)
    ymin = as.numeric(spatial_extent$south)
    xmax = as.numeric(spatial_extent$east)
    ymax = as.numeric(spatial_extent$north)
    message("...After Spatial extent")

    # spatial extent for stac call
    xmin_stac = xmin
    ymin_stac = ymin
    xmax_stac = xmax
    ymax_stac = ymax
    message("....After default Spatial extent for stac")
    if(crs != 4326){
      message("....crs is not 4326")
      min_pt <- sf::st_sfc(st_point(c(xmin, ymin)), crs = crs)
      min_pt <- sf::st_transform(min_pt, crs = 4326)
      min_bbx <- sf::st_bbox(min_pt)
      xmin_stac <- min_bbx$xmin
      ymin_stac <- min_bbx$ymin
      max_pt <- sf::st_sfc(st_point(c(xmax, ymax)), crs = crs)
      max_pt <- sf::st_transform(max_pt, crs = 4326)
      max_bbx <- sf::st_bbox(max_pt)
      xmax_stac <- max_bbx$xmax
      ymax_stac <- max_bbx$ymax
      message("....transformed to 4326")
    }

    # Connect to STAC API and get satellite data
    message("STAC API call.....")
    stac_object <- stac("https://earth-search.aws.element84.com/v0")
    items <- stac_object %>%
      stac_search(
        collections = id,
        bbox = c(xmin_stac, ymin_stac, xmax_stac, ymax_stac),
        datetime =  time_range,
        limit = 10000
      ) %>%
      post_request() %>%
      items_fetch()
    # create image collection from stac items features
    img.col <- stac_image_collection(items$features, property_filter =
                                       function(x) {x[["eo:cloud_cover"]] < 30})
    # Define cube view with monthly aggregation
     crs <- c("EPSG", crs)
     crs <- paste(crs, collapse=":")
     v.overview <- cube_view(srs=crs, dx=pixels_size, dy=pixels_size, dt=time_aggregation,
                  aggregation="median", resampling = "average",
                  extent=list(t0 = t0, t1 = t1,
                              left=xmin, right=xmax,
                              top=ymax, bottom=ymin))
    # gdalcubes creation
    cube <- raster_cube(img.col, v.overview)

    if(! is.null(bands)) {
      cube = select_bands(cube, bands)
    }
    message("Data Cube is created....")
    message(as_json(cube))
    return(cube)
  }
)


#' filter bands
filter_bands = Process$new(
  id = "filter_bands",
  description = "Filters the bands in the data cube so that bands that don't match any of the criteria are dropped from the data cube.",
  categories = as.array("cubes", "filter"),
  summary = "Filter the bands by name",
  parameters = list(
    Parameter$new(
      name = "data",
      description = "A data cube with bands.",
      schema = list(
        type = "object",
        subtype = "raster-cube")
    ),
    Parameter$new(
      name = "bands",
      description = "A list of band names.",
      schema = list(
        type = "array"),
      optional = TRUE
    )
  ),
  returns = eo_datacube,
  operation = function(data, bands, job) {
    if(! is.null(bands)) {
      cube = select_bands(data, bands)
    }
    message("Filtered data cube ....")
    message(as_json(cube))
    return(cube)
  }
)

#' filter bbox
filter_bbox = Process$new(
  id = "filter_bbox",
  description = "The filter retains a pixel in the data cube if the point at the pixel center intersects with the bounding box (as defined in the Simple Features standard by the OGC).",
  categories = as.array("cubes", "filter"),
  summary = "Limits the data cube to the specified bounding box.",
  parameters = list(
    Parameter$new(
      name = "data",
      description = "A data cube.",
      schema = list(
        type = "object",
        subtype = "raster-cube")
    ),
    Parameter$new(
      name = "extent",
      description = "A bounding box, which may include a vertical axis (see base and height).",
      schema = list(
        title = "Bounding box",
        type = "object",
        subtype = "bounding-box",
        properties = list(
          east = list(
            description = "East (upper right corner, coordinate axis 1).",
            type = "number"),
          west = list(
            description = "West lower left corner, coordinate axis 1).",
            type = "number"),
          north = list(
            description = "North (upper right corner, coordinate axis 2).",
            type = "number"),
          south = list(
            description = "South (lower left corner, coordinate axis 2).",
            type = "number")
        ),
      required = c("east", "west", "south", "north"))
    )
  ),
  returns = eo_datacube,
  operation = function(data, extent, job) {
    crs = srs(data)
    nw = c(extent$west, extent$north)
    sw = c(extent$west, extent$south)
    se = c(extent$east, extent$south)
    ne = c(extent$east, extent$north)

    p = list(rbind(nw, sw, se, ne, nw))
    pol = sf::st_polygon(p)

    cube = filter_geom(data, pol, srs = crs)

    return(cube)
  }
)

#' filter_spatial
filter_spatial = Process$new(
  id = "filter_spatial",
  description = "Limits the data cube over the spatial dimensions to the specified geometries.",
  categories = as.array("cubes"),
  summary = "Spatial filter using geometries",
  parameters = list(
    Parameter$new(
      name = "data",
      description = "A data cube.",
      schema = list(
        type = "object",
        subtype = "raster-cube")
    ),
    Parameter$new(
      name = "geometries",
      description = "One or more geometries used for filtering, specified as GeoJSON. NB: pass on a url e.g.. \"http....geojson\".",
      schema = list(
        type = "object"),
      optional = FALSE
    )
  ),
  returns = eo_datacube,
  operation = function(data, geometries, job) {
    # read geojson url and convert to geometry
    geo.data = read_sf(geometries)
    geo.data = geo.data$geometry
    geo.data = st_transform(geo.data, 3857)
    # filter using geom
    cube = filter_geom(data_cube, geo.data)
    return (cube)
  }
)



#' filter temporal
filter_temporal = Process$new(
  id = "filter_temporal",
  description = "Limits the data cube to the specified interval of dates and/or times.",
  categories = as.array("cubes", "filter"),
  summary = "Temporal filter based on temporal intervals",
  parameters = list(
    Parameter$new(
      name = "data",
      description = "A data cube with temporal dimensions.",
      schema = list(
        type = "object",
        subtype = "raster-cube")
    ),
    Parameter$new(
      name = "extent",
      description = "Left-closed temporal interval, i.e. an array with exactly two elements. e.g. c(\"2015-01-01\", \"2016-01-01\")",
      schema = list(
        type = "array"),
      optional = FALSE
    )
  ),
  returns = eo_datacube,
  operation = function(data, extent, dimension = NULL, job) {
    if(! is.null(extent)) {
      cube = select_time(data, c(extent[1], extent[2]))
    }
    return(cube)
  }
)

#' ndvi
ndvi = Process$new(
  id = "ndvi",
  description = "Computes the Normalized Difference Vegetation Index (NDVI). The NDVI is computed as (nir - red) / (nir + red).",
  categories = as.array("cubes"),
  summary = "Normalized Difference Vegetation Index",
  parameters = list(
    Parameter$new(
      name = "data",
      description = "A data cube with bands.",
      schema = list(
        type = "object",
        subtype = "raster-cube")
    ),
    Parameter$new(
      name = "nir",
      description = "The name of the NIR band. Defaults to the band that has the common name nir assigned..",
      schema = list(
        type = "string"),
      optional = FALSE
    ),
    Parameter$new(
      name = "red",
      description = "The name of the red band. Defaults to the band that has the common name red assigned.",
      schema = list(
        type = "string"),
      optional = FALSE
    ),
    Parameter$new(
      name = "target_band",
      description = "By default, the dimension of type bands is dropped. To keep the dimension specify a new band name in this parameter so that a new dimension label with the specified name will be added for the computed values.",
      schema = list(
        type = "string"),
      optional = TRUE
    )

  ),
  returns = eo_datacube,
  operation = function(data, nir= "nir", red = "red",target_band = NULL, job) {
    if((toString(nir) =="B08") && (toString(red) == "B04")){
      cube = apply_pixel(data,"(B08-B04)/(B08+B04)", names = "NDVI", keep_bands=FALSE)
      message("ndvi calculated ....")
      message(as_json(cube))
      return(cube)
    }else if((toString(nir) =="B05") && (toString(red) == "B04")){
      cube = apply_pixel(data,"(B05-B04)/(B05+B04)", names = "NDVI", keep_bands=FALSE)
      message("ndvi calculated ....")
      message(as_json(cube))
      return(cube)
    }else{
      cube = apply_pixel(data,"(nir-red)/(nir+red)", names = "NDVI", keep_bands=FALSE)
      message("ndvi calculated ....")
      message(as_json(cube))
      return(cube)
    }

  }
)


#' rename_dimension
rename_dimension = Process$new(
  id = "rename_dimension",
  description = "Renames a dimension in the data cube while preserving all other properties.",
  categories = as.array("cubes"),
  summary = "Rename a dimension",
  parameters = list(
    Parameter$new(
      name = "data",
      description = "A data cube with bands.",
      schema = list(
        type = "object",
        subtype = "raster-cube")
    ),
    Parameter$new(
      name = "source",
      description = "The current name of the dimension.",
      schema = list(
        type = "string"),
      optional = FALSE
    ),
    Parameter$new(
      name = "target",
      description = "A new Name for the dimension.",
      schema = list(
        type = "string"),
      optional = FALSE
    )
  ),
  returns = eo_datacube,
  operation = function(data, ..., job) {
    arguments <- list(data, ...)
    cube <- do.call(rename_bands, arguments)
    message("Renamed Data Cube....")
    message(as_json(cube))
    return(cube)
  }
)

#' reduce dimension
reduce_dimension = Process$new(
  id = "reduce_dimension",
  description = "Applies a unary reducer to a data cube dimension by collapsing all the pixel values along the specified dimension into an output value computed by the reducer. ",
  categories = as.array("cubes", "reducer"),
  summary = "Reduce dimensions",
  parameters = list(
    Parameter$new(
      name = "data",
      description = "A data cube with bands.",
      schema = list(
        type = "object",
        subtype = "raster-cube")
    ),
    Parameter$new(
      name = "reducer",
      description = "A reducer to apply on the specified dimension.",
      schema = list(
        type = "object",
        subtype = "process-graph",
        parameters = list(
          Parameter$new(
            name = "data",
            description = "A labeled array with elements of any type.",
            schema = list(
              type = "array",
              subtype = "labeled-array",
              items = list(description = "Any data type")
            )
          ),
          Parameter$new(
            name = "context",
            description = "Additional data passed by the user.",
            schema = list(
              description = "Any data type"),
            optional = TRUE
          )
        )
      )
    ),
    Parameter$new(
      name = "dimension",
      description = "The name of the dimension over which to reduce.",
      schema = list(
        type = "string")
    ),
    Parameter$new(
      name = "context",
      description = "Additional data to be passed to the reducer.",
      schema = list(
        description = "Any data type"),
      optional = TRUE
    )
  ),
  returns = eo_datacube,
  operation = function(data, reducer, dimension, job) {
    if(dimension == "t" || dimension == "time") {

      bands = bands(data)$name
      bandStr = c()

      for (i in 1:length(bands)) {
        bandStr = append(bandStr, sprintf("%s(%s)", reducer, bands[i]))
      }

      cube = reduce_time(data, bandStr)
      return(cube)
    }
    else if (dimension == "bands") {

      cube = apply_pixel(data, reducer, keep_bands = FALSE)
      return(cube)
    }
    else {
      stop('Please select "t", "time" or "bands" as dimension')
    }
  }
)

#' merge_cubes
merge_cubes = Process$new(
  id = "merge_cubes",
  description = "The data cubes have to be compatible. The two provided data cubes will be merged into one data cube. The overlap resolver is not supported.",
  categories = as.array("cubes"),
  summary = "Merging two data cubes",
  parameters = list(
    Parameter$new(
      name = "data1",
      description = "A data cube.",
      schema = list(
        type = "object",
        subtype = "raster-cube")
    ),
    Parameter$new(
      name = "data2",
      description = "A data cube.",
      schema = list(
        type = "object",
        subtype = "raster-cube")
    ),
    Parameter$new(
      name = "context",
      description = "Additional data passed by the user.",
      schema = list(description = "Any data type."),
      optional = TRUE
    )
  ),
  returns = eo_datacube,
  operation = function(data1, data2, context, job) {

    if("cube" %in% class(data1) && "cube" %in% class(data2)) {

      compare = compare.list(dimensions(data1), dimensions(data2))

      if(FALSE %in% compare) {
        stop("Dimensions of datacubes are not equal")
      }
      else {
        cube = join_bands(c(data1, data2))
        return(cube)
      }
    }
    else {
      stop('Provided cubes are not of class "cube"')
    }
  }
)

#'array element
array_element = Process$new(
  id = "array_element",
  description = "Returns the element with the specified index or label from the array.",
  categories = as.array("arrays", "reducer"),
  summary = "Get an element from an array",
  parameters = list(
    Parameter$new(
      name = "data",
      description = "An array",
      schema = list(type = "array")
    ),
    Parameter$new(
      name = "index",
      description = "The zero-based index of the element to retrieve.",
      schema = list(type ="integer"),
      optional = TRUE
    ),
    Parameter$new(
      name = "label",
      description = "The label of the element to retrieve.",
      schema = list(type =c("number", "string")),
      optional = TRUE
    ),
    Parameter$new(
      name = "return_nodata",
      description = "By default this process throws an ArrayElementNotAvailable exception if the index or label is invalid. If you want to return null instead, set this flag to true.",
      schema = list(type ="boolean"),
      optional = TRUE
    )
  ),
  returns = list(
    description = "The value of the requested element.",
    schema = list(description = "Any data type is allowed.")),
  operation = function(data, index = NULL, label = NULL, return_nodata = FALSE, job) {

    if (class(data) == "list") {
      bands = bands(data$data)$name
    }
    else {
      bands = bands(data)$name
    }


    if(! is.null(index)) {
      band = bands[index]
    }
    else if (! is.null(label) && label %in% bands) {
      band = label
    }
    else {
      stop("Band not found")
    }
    return(band)
  }
)

#'rename labels
rename_labels = Process$new(
  id = "rename_labels",
  description = "Renames the labels of the specified dimension in the data cube from source to target.",
  categories = as.array("cubes"),
  summary = "Rename dimension labels",
  parameters = list(
    Parameter$new(
      name = "data",
      description = "The data cube.",
      schema = list(
        type = "object",
        subtype = "raster-cube")
    ),
    Parameter$new(
      name = "dimension",
      description = "The name of the dimension to rename the labels for.",
      schema = list(type = "string")
    ),
    Parameter$new(
      name = "target",
      description = "The new names for the labels.",
      schema = list(
        type = "array",
        items = list(type = c("number", "string")))
    ),
    Parameter$new(
      name = "source",
      description = "The names of the labels as they are currently in the data cube.",
      schema = list(
        type = "array",
        items = list(type = c("number", "string"))),
      optional = TRUE
    )
  ),
  returns = eo_datacube,
  operation = function(data, dimension, target, source = NULL, job) {
    if (dimension == "bands") {
      if (! is.null(source)) {
          if(class(source) == "number" || class(source) == "integer") {
            band = as.character(bands(data)$name[source])
            cube = apply_pixel(data, band, names = target)
          }
          else if (class(source) == "string" || class(source) == "character") {
            cube = apply_pixel(data, source, names = target)
          }
          else {
            stop("Source is not a number or string")
          }
      }
      else {
        band = as.character(bands(data)$name[1])
        cube = apply_pixel(data, band, names = target)
      }
      return(cube)
    }
    else {
      stop("Only bands dimension supported")
    }
  }
)


#' run_udf
run_udf = Process$new(
  id = "run_udf",
  description = "Runs a UDF . Run the source code specified inline as string.",
  categories = as.array("cubes"),
  summary = "Run a user-defined function(UDF)",
  parameters = list(
    Parameter$new(
      name = "data",
      description = "A data cube.",
      schema = list(
        type = "object",
        subtype = "raster-cube")
    ),
    Parameter$new(
      name = "udf",
      description = "The multi-line source code of a UDF.",
      schema = list(
        type = "string",
        subtype = "string")
    ),
    Parameter$new(
      name = "names",
      description = "List of names to define outputs from a reducer UDF",
      schema = list(
        type = "string",
        subtype = "string")
    ),
    Parameter$new(
      name = "runtime",
      description = "A UDF runtime identifier available at the back-end.",
      schema = list(
        type = "string",
        subtype = "string")
    ),
    Parameter$new(
      name = "context",
      description = "Additional data passed by the user.",
      schema = list(description = "Any data type."),
      optional = TRUE
    )
  ),
  returns = list(
    description = "The computed result.",
    schema = list(type = c("number", "null"))),
  operation = function(data, udf, names = c("default"),context = NULL, runtime = NULL, version = NULL, job) {
    # NB : more reducer keywords can be added
    message("run UDF called")
    reducer.keywords = c("sum","bfast","sd", "mean", "median", "min","reduce","product", "max", "count", "var")
    if("cube" %in% class(data)) {
      if(grepl("function", udf)){
        if(any(sapply(reducer.keywords, grepl, udf))){
          # convert parsed string function to class function
          func.parse = parse(text = udf)
          user.function = eval(func.parse)
          # reducer udf
          message("reducer function -> time")
          data = reduce_time(data, names= names, FUN = user.function)
          return (data)
        }else{
          # convert parsed string function to class function
          message("apply per pixel function")
          func.parse = parse(text = udf)
          user.function = eval(func.parse)
          # apply per pixel udf
          data = apply_pixel(data, FUN = user.function)
          return (data)
        }
      }else{
        message("simple reducer udf")
        data = reduce_time(data, udf)
        return (data)
      }
    }
    else {
      stop('Provided cube is not of class "cube"')
    }
  }
)


#' save result
save_result = Process$new(
  id = "save_result",
  description = "Saves processed data to the local user workspace / data store of the authenticated user.",
  categories = as.array("cubes", "export"),
  summary = "Save processed data to storage",
  parameters = list(
    Parameter$new(
      name = "data",
      description = "The data to save.",
      schema = list(
        type = "object",
        subtype = "raster-cube")
    ),
    Parameter$new(
      name = "format",
      description = "The file format to save to.",
      schema = list(
        type = "string",
        subtype = "output-format")
    ),
    Parameter$new(
      name = "options",
      description = "The file format parameters to be used to create the file(s).",
      schema = list(
        type = "object",
        subtype = "output-format-options"),
      optional = TRUE
    )
  ),
  returns = list(
    description = "false if saving failed, true otherwise.",
    schema = list(type = "boolean")
  ),
  operation = function(data, format, options = NULL, job) {
    gdalcubes_options(parallel = 8)
    message("Data is being saved in format :")
    message(format)
    message("The above format is being saved")
    job$setOutput(format)
    return(data)
  }
)



