#' Run a dplyr query and store the result in a permanent table
#'
#' @param x A dplyr query
#' @param name Name of the table to be created
#' @param schema Schema to create the new table in
#' Can be a length 1 or 2 vector.
#' (e.g. schema = "my_schema", schema = c("my_schema", "dbo))
#' @param overwrite If the table already exists in the remote database
#' should it be overwritten? (TRUE or FALSE)
#'
#' @return A dplyr reference to the newly created table
#' @export
#'
#' @examples
#' \dontrun{
#' library(CDMConnector)
#'
#' con <- DBI::dbConnect(duckdb::duckdb(), dbdir = CDMConnector::eunomia_dir())
#' concept <- dplyr::tbl(con, "concept")
#'
#' rxnorm_count <- concept %>%
#'   dplyr::filter(domain_id == "Drug") %>%
#'   dplyr::mutate(isRxnorm = (vocabulary_id == "RxNorm")) %>%
#'   dplyr::count(isRxnorm) %>%
#'   computePermanent("rxnorm_count")
#'
#' DBI::dbDisconnect(con, shutdown = TRUE)
#' }
computePermanent <- function(x, name, schema = NULL, overwrite = FALSE) {
  checkmate::assertCharacter(schema, min.len = 1, max.len = 2, null.ok = TRUE)
  checkmate::assertCharacter(name, len = 1)
  checkmate::assertClass(x, "tbl_sql")
  checkmate::assertLogical(overwrite, len = 1)

  if (length(schema) == 2) {
    fullNameQuoted <- paste(DBI::dbQuoteIdentifier(x$src$con, schema[[1]]),
                            DBI::dbQuoteIdentifier(x$src$con, schema[[2]]),
                            DBI::dbQuoteIdentifier(x$src$con, name),
                            sep = ".")
  } else if (length(schema) == 1) {
    fullNameQuoted <- paste(DBI::dbQuoteIdentifier(x$src$con, schema),
                            DBI::dbQuoteIdentifier(x$src$con, name),
                            sep = ".")
  } else {
    fullNameQuoted <- DBI::dbQuoteIdentifier(x$src$con, name)
  }

  existingTables <- CDMConnector::listTables(x$src$con, schema = schema)
  if (name %in% existingTables) {
    if (overwrite) {
      DBI::dbRemoveTable(x$src$con, DBI::SQL(fullNameQuoted))
    } else {
      rlang::abort(paste(fullNameQuoted, "already exists.",
                         "Set overwrite = TRUE to recreate it."))
    }
  }

  if (CDMConnector::dbms(x$src$con) == "spark" &&
      !rlang::is_installed("SqlRender", version = "1.8.0")) {
    rlang::abort("SqlRender version 1.8.0 or later is required
                 to use computePermanent with spark.")
  }

  if (CDMConnector::dbms(x$src$con) %in% c("duckdb", "oracle")) {
    sql <- dbplyr::build_sql("CREATE TABLE ",
             if (!is.null(schema)) dbplyr::ident(schema),
             if (!is.null(schema)) dbplyr::sql("."), dbplyr::ident(name),
             " AS ", dbplyr::sql_render(x), con = x$src$con)

  } else if (CDMConnector::dbms(x$src$con) == "spark") {
    sql <- dbplyr::build_sql("CREATE ",
             if (overwrite) dbplyr::sql("OR REPLACE "),  "TABLE ",
             if (!is.null(schema)) dbplyr::ident(schema),
             if (!is.null(schema)) dbplyr::sql("."), dbplyr::ident(name),
             " AS ", dbplyr::sql_render(x), con = x$src$con)
  } else {
    sql <- glue::glue("SELECT * INTO {fullNameQuoted}
                      FROM ({dbplyr::sql_render(x)}) x")
    sql <- SqlRender::translate(sql,
                                targetDialect = CDMConnector::dbms(x$src$con))
  }

  DBI::dbExecute(x$src$con, sql)

  if (is(x$src$con, "duckdb_connection")) {
    ref <- dplyr::tbl(x$src$con, paste(c(schema, name), collapse = "."))
  } else if (length(schema) == 2) {
    ref <- dplyr::tbl(x$src$con,
                      dbplyr::in_catalog(schema[[1]], schema[[2]], name))
  } else if (length(schema) == 1) {
    ref <- dplyr::tbl(x$src$con, dbplyr::in_schema(schema, name))
  } else {
    ref <- dplyr::tbl(x$src$con, name)
  }
  return(ref)
}

#' Run a dplyr query and add the result set to an existing
#'
#' @param x A dplyr query
#' @param name Name of the table to be appended. If it does not already exist it
#'   will be created.
#' @param schema Schema where the table exists. Can be a length 1 or 2 vector.
#'   (e.g. schema = "my_schema", schema = c("my_schema", "dbo))
#'
#' @return A dplyr reference to the newly created table
#' @export
#'
#' @examples
#' \dontrun{
#' library(CDMConnector)
#' library(SqlUtilities)
#'
#' con <- DBI::dbConnect(duckdb::duckdb(), dbdir = CDMConnector::eunomia_dir())
#' concept <- dplyr::tbl(con, "concept")
#'
#' # create a table
#' rxnorm_count <- concept %>%
#'   dplyr::filter(domain_id == "Drug") %>%
#'   dplyr::mutate(isRxnorm = (vocabulary_id == "RxNorm")) %>%
#'   dplyr::count(domain_id, isRxnorm) %>%
#'   computePermanent("rxnorm_count")
#'
#' # append to an existing table
#' rxnorm_count <- concept %>%
#'   dplyr::filter(domain_id == "Procedure") %>%
#'   dplyr::mutate(isRxnorm = (vocabulary_id == "RxNorm")) %>%
#'   dplyr::count(domain_id, isRxnorm) %>%
#'   appendPermanent("rxnorm_count")
#'
#' DBI::dbDisconnect(con, shutdown = TRUE)
#'
#' }
appendPermanent <- function(x, name, schema = NULL) {
  checkmate::assertCharacter(schema, min.len = 1, max.len = 2, null.ok = TRUE)
  checkmate::assertCharacter(name, len = 1)
  checkmate::assertClass(x, "tbl_sql")

  if (length(schema) == 2) {
    fullNameQuoted <- paste(DBI::dbQuoteIdentifier(x$src$con, schema[[1]]),
                            DBI::dbQuoteIdentifier(x$src$con, schema[[2]]),
                            DBI::dbQuoteIdentifier(x$src$con, name),
                            sep = ".")
  } else if (length(schema) == 1) {
    fullNameQuoted <- paste(DBI::dbQuoteIdentifier(x$src$con, schema),
                            DBI::dbQuoteIdentifier(x$src$con, name),
                            sep = ".")
  } else {
    fullNameQuoted <- DBI::dbQuoteIdentifier(x$src$con, name)
  }

  existingTables <- CDMConnector::listTables(x$src$con, schema = schema)
  if (!(tolower(name) %in% tolower(existingTables))) {
    return(computePermanent(x = x,
                            name = name,
                            schema = schema,
                            overwrite = FALSE))
  }

  sql <- glue::glue("INSERT INTO {fullNameQuoted} {dbplyr::sql_render(x)}")
  sql <- SqlRender::translate(sql,
                              targetDialect = CDMConnector::dbms(x$src$con))

  DBI::dbExecute(x$src$con, sql)

  if (length(schema) == 2) {
    ref <- dplyr::tbl(x$src$con,
                      dbplyr::in_catalog(schema[[1]], schema[[2]], name))
  } else if (length(schema) == 1) {
    ref <- dplyr::tbl(x$src$con, dbplyr::in_schema(schema, name))
  } else {
    ref <- dplyr::tbl(x$src$con, name)
  }
  return(ref)
}

uniqueTableName <- function() {
  i <- getOption("dbplyr_table_name", 0) + 1
  options(dbplyr_table_name = i)
  sprintf("dbplyr_%03i", i)
}

#' Execute dplyr query and save result in remote database
#'
#' This function is a wrapper around `dplyr::compute` that is tested on several
#' database systems. It is needed to handle edge cases where `dplyr::compute`
#' does not produce correct SQL.
#'
#' @param x A dplyr query
#' @param name The name of the table to create.
#' @param temporary Should the table be temporary: TRUE (default) or FALSE
#' @param schema The schema where the table should be created. Ignored if
#'   temporary = TRUE.
#' @param overwrite Should the table be overwritten if it already exists: TRUE
#'   or FALSE (default) Ignored if temporary = TRUE.
#' @param ... Further arguments passed on the `dplyr::compute`
#'
#' @return A `dplyr::tbl()` reference to the newly created table.
#' @export
computeQuery <- function(x,
                         name = uniqueTableName(),
                         temporary = TRUE,
                         schema = NULL,
                         overwrite = FALSE,
                         ...) {

  checkmate::assertLogical(temporary, len = 1)

  con <- x$src$con

  if (temporary) {
    if (is(con, "OraConnection") || is(con, "Oracle")) {
      # https://github.com/tidyverse/dbplyr/issues/621#issuecomment-1362229669
      name <- paste0("ORA$PTT_", name)
      sql <- dbplyr::build_sql(
        "CREATE PRIVATE TEMPORARY TABLE \n",
        dbplyr::ident(name),
        dbplyr::sql(" ON COMMIT PRESERVE DEFINITION \n"),
        " AS\n",
        dbplyr::sql_render(x),
        con = con
      )
      DBI::dbExecute(con, sql)
      return(dplyr::tbl(con, name))
    } else if (is(con, "Spark SQL")) {
      sql <- dbplyr::build_sql(
        "CREATE ", if (overwrite) dbplyr::sql("OR REPLACE "),
        "TEMPORARY VIEW \n",
        dbplyr::ident(name), " AS\n",
        dbplyr::sql_render(x),
        con = con
      )
      DBI::dbExecute(con, sql)
      return(dplyr::tbl(con, name))
    } else {
      return(dplyr::compute(x, name = name, temporary = temporary, ...))
    }
  } else {
    computePermanent(x, name = name, schema = schema, overwrite = overwrite)
  }
}
