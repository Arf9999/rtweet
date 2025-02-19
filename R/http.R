TWIT_get <- function(token, api, params = NULL, ..., host = "api.twitter.com") {
  resp <- TWIT_method("GET", 
    token = token, 
    api = api,
    params = params,
    ...,
    host = host
  )
  
  from_js(resp)
}

TWIT_post <- function(token, api, params = NULL, body = NULL, ..., host = "api.twitter.com") {
  TWIT_method("POST", 
    token = token, 
    api = api,
    params = params,
    body = body,
    ...,
    host = host
  )
}

TWIT_method <- function(method, token, api, 
                        params = NULL, 
                        host = "api.twitter.com",
                        retryonratelimit = NULL,
                        verbose = TRUE,
                        ...) {
  # need scipen to ensure large IDs are not displayed in scientific notation
  # need ut8-encoding for the comma separated IDs
  withr::local_options(scipen = 14, encoding = "UTF-8")

  token <- check_token(token)
  url <- paste0("https://", host, api, ".json")
  
  resp <- switch(method,
                 GET = httr::GET(url, query = params, token, ...),
                 POST = httr::POST(url, query = params, token, ...),
                 stop("Unsupported method", call. = FALSE)
  )
  
  switch(resp_type(resp),
         ok = NULL,
         protected = handle_protected(params),
         rate_limit = handle_rate_limit(
           resp, api, 
           retryonratelimit = retryonratelimit,
           verbose = verbose
         ),
         error = handle_error(resp)
  )

  resp
}

#' Pagination
#' 
#' @description 
#' `r lifecycle::badge("experimental")`
#' These are internal functions used for pagination inside of rtweet.
#' 
#' @keywords internal
#' @param token Expert use only. Use this to override authentication for
#'   a single API call. In most cases you are better off changing the
#'   default for all calls. See [auth_as()] for details.
#' @param n Desired number of results to return. Results are downloaded
#'   in pages when `n` is large; the default value will download a single
#'   page. Set `n = Inf` to download as many results as possible.
#'   
#'   The Twitter API rate limits the number of requests you can perform
#'   in each 15 minute period. The easiest way to download more than that is 
#'   to use `retryonratelimit = TRUE`.
#'   
#'   You are not guaranteed to get exactly `n` results back. You will get
#'   fewer results when tweets have been deleted or if you hit a rate limit. 
#'   You will get more results if you ask for a number of tweets that's not
#'   a multiple of page size, e.g. if you request `n = 150` and the page
#'   size is 200, you'll get 200 results back.
#' @param get_id A single argument function that returns a vector of ids given 
#'   the JSON response. The defaults are chosen to cover the most common cases,
#'   but you'll need to double check whenever implementing pagination for
#'   a new endpoint.
#' @param max_id Supply a vector of ids or a data frame of previous results to 
#'   find tweets **older** than `max_id`.
#' @param since_id Supply a vector of ids or a data frame of previous results to 
#'   find tweets **newer** than `since_id`.
#' @param retryonratelimit If `TRUE`, and a rate limit is exhausted, will wait
#'   until it refreshes. Most Twitter rate limits refresh every 15 minutes.
#'   If `FALSE`, and the rate limit is exceeded, the function will terminate
#'   early with a warning; you'll still get back all results received up to 
#'   that point. The default value, `NULL`, consults the option 
#'   `rtweet.retryonratelimit` so that you can globally set it to `TRUE`, 
#'   if desired.
#'   
#'   If you expect a query to take hours or days to perform, you should not 
#'   rely soley on `retryonratelimit` because it does not handle other common
#'   failure modes like temporarily losing your internet connection.
#' @param parse If `TRUE`, the default, returns a tidy data frame. Use `FALSE` 
#'   to return the "raw" list corresponding to the JSON returned from the 
#'   Twitter API.
#' @param verbose Show progress bars and other messages indicating current 
#'   progress?
TWIT_paginate_max_id <- function(token, api, params, 
                                 get_id = function(x) x$id_str, 
                                 n = 1000, 
                                 page_size = 200, 
                                 since_id = NULL,
                                 max_id = NULL,
                                 count_param = "count", 
                                 retryonratelimit = NULL,
                                 verbose = TRUE) {
  if (!is.null(max_id)) {
    max_id <- rtweet::max_id(max_id)  
  }
  if (!is.null(since_id)) {
    since_id <- rtweet::since_id(since_id)  
  }
  
  params$since_id <- since_id
  params[[count_param]] <- page_size  
  pages <- ceiling(n / page_size)
  results <- vector("list", if (is.finite(pages)) pages else 1000)
  
  if (verbose)  {
    pb <- progress::progress_bar$new(
      format = "Downloading multiple pages :bar",
      total = pages
    ) 
    withr::defer(pb$terminate())
  }
  
  i <- 0
  while (i < pages) {
    i <- i + 1
    params$max_id <- max_id
    if (i == pages) {
      params[[count_param]] <- n - (pages - 1) * page_size
    }

    json <- catch_rate_limit(
      TWIT_get(
        token, api, params, 
        retryonratelimit = retryonratelimit,
        verbose = verbose
      )
    )
    if (is_rate_limit(json)) {
      warn_early_term(json, 
        hint = paste0("Set `max_id = '", max_id, "' to continue."),
        hint_if = !is.null(max_id)
      )
      break
    }

    id <- get_id(json)
    # no more tweets to return
    if (length(id) == 0) {
      break
    }
    if(i > length(results)) { 
      # double length per https://en.wikipedia.org/wiki/Dynamic_array#Geometric_expansion_and_amortized_cost
      length(results) <- 2 * length(results)
    }
    
    max_id <- max_id(id)
    results[[i]] <- json
    
    if (verbose) {
      pb$tick()
    }
  }
  results
}

# https://developer.twitter.com/en/docs/pagination
#' @rdname TWIT_paginate_max_id
#'  
#' @param cursor Which page of results to return. The default will return 
#'   the first page; you can supply the result from a previous call to 
#'   continue pagination from where it left off.
TWIT_paginate_cursor <- function(token, api, params, 
                                 n = 5000, 
                                 page_size = 5000, 
                                 cursor = "-1", 
                                 get_id = function(x) x$ids,
                                 retryonratelimit = NULL,
                                 verbose = TRUE) {
  params$count <- page_size
  cursor <- next_cursor(cursor)
  if (identical(cursor, "0")) {
    # Last request retrieved all available results
    return(list())
  }
  
  # TODO: consider if its worth using fastmap::faststack() here
  results <- list()
  i <- 1
  n_seen <- 0
  
  if (verbose) {
    pb <- progress::progress_bar$new(
      format = "Downloading multiple pages :bar",
      total = n
    ) 
    withr::defer(pb$terminate())
  }

  repeat({
    params$cursor <- cursor
    json <- catch_rate_limit(
      TWIT_get(
        token, api, params, 
        retryonratelimit = retryonratelimit,
        verbose = verbose
      )
    )

    if (is_rate_limit(json)) {
      if (!is.null(retryonratelimit)){
        warn_early_term(json, 
                        hint = paste0("Set `cursor = '", cursor, "' to continue."),
                        hint_if = !identical(cursor, "-1")
        )
      }
      break
    }

    results[[i]] <- json
    if (any(grepl("next_cursor", names(json)))) {
      cursor <- ifelse(!is.null(json$next_cursor_str), 
                       json$next_cursor_str, 
                       json$next_cursor)
    } else {
      # If next_cursor is missing there are no message within the last 30 days
      cursor <- "0" 
    }
    n_seen <- n_seen + length(get_id(json))
    i <- i + 1

    if (identical(cursor, "0") || n_seen >= n || length(json$events) == 0) {
      break
    }
    
    if (verbose) {
      pb$update(n_seen / n)
    }
  })

  structure(results, rtweet_cursor = cursor)
}

#' @rdname TWIT_paginate_max_id
#'  
TWIT_paginate_chunked <- function(token, api, params_list, 
                                  retryonratelimit = NULL, 
                                  verbose = TRUE) {
  

  pages <- length(params_list)
  results <- vector("list", pages)
  
  if (verbose)  {
    pb <- progress::progress_bar$new(
      format = "Downloading multiple pages :bar",
      total = pages
    ) 
    withr::defer(pb$terminate())
  }

  for (i in seq_along(params_list)) {
    params <- params_list[[i]]
    json <- catch_rate_limit(
      TWIT_get(
        token, api, params, 
        retryonratelimit = retryonratelimit,
        verbose = verbose
      )
    )
    if (is_rate_limit(json)) {
      warn_early_term(json, hint_if = FALSE)
      break
    }
    
    results[[i]] <- json
    
    if (verbose) {
      pb$tick()
    }
  }

  results
}  


# helpers -----------------------------------------------------------------

from_js <- function(resp) {
  if (!grepl("application/json", resp$headers[["content-type"]])) {
    stop("API did not return json", call. = FALSE)
  }
  resp <- httr::content(resp, as = "text", encoding = "UTF-8")
  jsonlite::fromJSON(resp)
}

resp_type <- function(resp) {
  x <- resp$status_code
  if (x == 429) {
    "rate_limit"
  } else if (x == 401) {
    "protected"
  } else if (x >= 400) {
    "error"
  } else {
    "ok"
  }
}

# Three possible exits:
# * skip, if testing
# * return, if retryonratelimit is TRUE
# * error, otherwise
handle_rate_limit <- function(x, api, retryonratelimit = NULL, verbose = TRUE) {
  if (is_testing()) {
    testthat::skip("Rate limit exceeded")
  }

  headers <- httr::headers(x)
  n <- headers$`x-rate-limit-limit`
  when <- .POSIXct(as.numeric(headers$`x-rate-limit-reset`))
  
  retryonratelimit <- retryonratelimit %||% getOption("rtweet.retryonratelimit", FALSE)
  
  if (retryonratelimit) {
    wait_until(when, api, verbose = verbose)
  } else {
    message <- c(
      paste0("Rate limit exceeded for Twitter endpoint '", api, "'"), 
      paste0("Will receive ", n, " more requests at ", format(when, "%H:%M"))
    )
    abort(message, class = "rtweet_rate_limit", when = when)
  }
}

# I don't love this interface because it returns either a httr response object
# or a condition object, but it's easy to understand and avoids having to do
# anything exotic to break from the correct frame.
catch_rate_limit <- function(code) {
  tryCatch(code, rtweet_rate_limit = function(e) e)
}

is_rate_limit <- function(x) inherits(x, "rtweet_rate_limit")

warn_early_term <- function(cnd, hint, hint_if) {
  warn(c(
    "Terminating paginate early due to rate limit.",
    cnd$message,
    i = if (hint_if) hint,
    i = "Set `retryonratelimit = TRUE` to automatically wait for reset"
  ))
}

# https://developer.twitter.com/en/support/twitter-api/error-troubleshooting
handle_error <- function(x) {
  json <- from_js(x)
  stop("Twitter API failed [", x$status_code, "]\n",
       paste0(" * ", json$errors$message, " (", json$errors$code, ")"),
       call. = FALSE)
}

handle_protected <- function(params) {
  if (any(c("screen_name", "user_id") %in% names(params))) {
    account <- params$screen_name
    if (is.null(account)) account <- params$user_id
  }
  warning("Skipping unauthorized account: ", account, call. = FALSE)
}

check_status <- function(x, api) {
  switch(resp_type(x),
    ok = NULL,
    rate_limit = ,
    error = handle_error(x)
  )
}

check_token <- function(token = NULL) {
  token <- token %||% auth_get()

  if (inherits(token, "Token1.0")) {
    token
  } else if (inherits(token, "rtweet_bearer")) {
    httr::add_headers(Authorization = paste0("Bearer ", token$token))
  } else {
    abort("`token` is not a valid access token")
  }
}
