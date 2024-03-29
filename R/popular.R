### const ----
credentals <- jsonlite::fromJSON(Sys.getenv("credentals"))
auth_google <- Sys.getenv("GKEY")
name_google <- credentals[["GNAME"]]
link <- credentals[["GLINK_PARSE"]]
link_parse <- credentals[["LINK_WEB"]]
result_popular <- credentals[["GPARSE_POPULAR"]]
icon_id <- credentals[["ICONID"]]
time_local <- "Europe/Moscow"
num_page <- 1
delay <- 0.3

### auth ----
file_con <- file(name_google)
writeLines(auth_google, file_con)
close(file_con)
googlesheets4::gs4_auth(path = name_google)

### get page items ----
get_pages_prop <- \(num_page) {
  page_link_parse <- glue::glue(link_parse)

  ### get items ----
  html <- page_link_parse |>
    rvest::read_html()

  items <- html |>
    rvest::html_elements(".fpa-list-item")

  get_prop <- \(item) {
    title <- item |>
      rvest::html_element(".internal")

    site <- title |>
      rvest::html_text2()

    link <- title |>
      rvest::html_attr("href")

    icon <- item |>
      rvest::html_element(".fa") |>
      rvest::html_attr("class")

    rating <- item |>
      rvest::html_element(".rating-stars") |>
      rvest::html_attr("style") |>
      stringr::str_extract("[0-9]+") |>
      as.numeric()

    reviews <- item |>
      rvest::html_element(".total") |>
      rvest::html_text2()

    result <- tibble::tibble(
      Site = site,
      Link = link,
      Rating = rating,
      Reviews = reviews,
      Icon = icon,
      Page = num_page
    )

    result
  }

  all_prop <- purrr::map_df(items, \(x) get_prop(x))
  Sys.sleep(delay)

  all_prop
}

### url first page ----
first_page <- glue::glue(link_parse)

### get num pages
count_pages <- rvest::read_html(first_page) |>
  rvest::html_element(".c-pagination__summary") |>
  rvest::html_text2() |>
  stringr::str_extract("(?<=of )[0-9]+") |>
  as.numeric()

pages <- seq_len(count_pages)

### get icons ----
icons <- googlesheets4::read_sheet(link, icon_id)

all_pages_prop <- purrr::map_df(pages, \(x) get_pages_prop(x)) |>
  dplyr::mutate(Rating = (.data$Rating / 100) * 5) |>
  dplyr::mutate(Icon = ifelse(is.na(.data$Icon), "", .data$Icon)) |>
  dplyr::filter(.data$Icon != "fa im im-ad") |>
  dplyr::left_join(icons, by = "Icon") |>
  dplyr::mutate(Icon = ifelse(.data$Icon == "", .data$Icon, .data$Value)) |>
  dplyr::select(-.data$Value) |>
  dplyr::mutate(Num = dplyr::row_number()) |>
  dplyr::mutate(`Other domain` = stringr::str_extract(.data$Site, "\\(.+\\)")) |>
  dplyr::mutate(Site = stringr::str_trim(stringr::str_remove(.data$Site, "\\(.+\\)"),
    side = "right"
  )) |>
  dplyr::mutate(dt_load = lubridate::now(tzone = time_local)) |>
  dplyr::mutate(dt_load = as.character(.data$dt_load)) |>
  dplyr::relocate(.data$`Other domain`, .after = .data$Site)


### write to table ----
googlesheets4::write_sheet(
  all_pages_prop,
  link,
  result_popular
)
