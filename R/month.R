### const ----
library(lubridate)  # Ensure lubridate is loaded
credentals <- jsonlite::fromJSON(Sys.getenv("credentals"))
# auth_clickup <- credentals[["CLICKUP"]] - This is Vlad's API key, and it has lower access levels.
auth_clickup <- Sys.getenv("NEW_CLICKUP_KEY") # This is Kira's API key, and it has highier access levels, thus we switched to using this key
auth_google <- Sys.getenv("GKEY")
name_google <- credentals[["GNAME"]]
team_id <- credentals[["TID"]]
team_name <- credentals[["TNAME"]]
link <- credentals[["GLINK_DB"]]
sheet_tm <- credentals[["GTT_MON"]]
sheet_crossing <- credentals[["GCROSSING_MON"]]

### utils ----
miliseconds <- 1000
time_local <- "Europe/Moscow"
delay <- 0.6
err_num_cols <- 2
err_desc <- "can't get list, folder, space"

### get team members id ----
teams <- httr::GET(
  "https://api.clickup.com/api/v2/team",
  httr::add_headers(Authorization = auth_clickup)
)

teams_json <- httr::content(teams, "parsed")

teams_ds <- tibble::tibble(result = teams_json[["teams"]]) |>
  tidyr::unnest_wider(col = .data[["result"]]) |>
  tidyr::unnest_longer(.data$members) |>
  tidyr::unnest_wider(.data$members, names_sep = "_") |>
  tidyr::unnest_wider(.data$members_user, names_sep = "_")

members_id <- unique(teams_ds$members_user_id) |>
  stringr::str_c(collapse = ",")

### get time entries ----
### now
now_posix <- lubridate::now(tzone = time_local)
### Determine if it's the first day of the month
is_first_day <- lubridate::day(now_posix) == 1

### Adjust start and end dates based on the day check
if (is_first_day) {
  ### If it's the first day, adjust start to the beginning of the previous month
  start_posix <- lubridate::floor_date(now_posix - months(1), "month")
  ### Adjust end to the end of the previous month
  end_posix <- lubridate::ceiling_date(now_posix - days(1), "month") - seconds(1)
} else {
  ### Regular start of current month
  start_posix <- lubridate::floor_date(now_posix, "month")
  ### Current time as end
  end_posix <- now_posix
}

### Convert to unix time in milliseconds
to_posix <- \(x) {
  rs <- as.POSIXct(x) |>
    as.numeric() |>
    ceiling()
  format(rs * miliseconds, scientific = FALSE)
}

start_posix <- to_posix(start_posix)
end_posix <- to_posix(end_posix)

### Fetch time entries with adjusted dates
time <- httr::GET(
  glue::glue("https://api.clickup.com/api/v2/team/{team_id}/time_entries?start_date={start_posix}&end_date={end_posix}&assignee={members_id}"),
  httr::add_headers(Authorization = auth_clickup)
)


time_json <- httr::content(time, "parsed")

time_ds <- dplyr::tibble(result = time_json[["data"]]) |>
  tidyr::unnest_wider(col = .data[["result"]]) |>
  tidyr::unnest_wider(.data$task, names_sep = "_") |>
  tidyr::unnest_wider(.data$user, names_sep = "_") |>
  dplyr::mutate(
    ### milliseconds
    start = as.numeric(.data$start) / miliseconds,
    end = as.numeric(.data$end) / miliseconds
  ) |>
  dplyr::mutate(
    start = lubridate::as_datetime(.data$start),
    end = lubridate::as_datetime(.data$end)
  ) |>
  dplyr::mutate(
    start = lubridate::with_tz(.data$start, tz = time_local),
    end = lubridate::with_tz(.data$end, tz = time_local)
  ) |>
  dplyr::mutate(
    start = as.character(.data$start),
    end = as.character(.data$end),
    duration_numeric = as.numeric(.data$duration),
    diff_hours = ifelse(is.na(duration_numeric), 0, duration_numeric / (3600 * 1000))
  ) |>
  dplyr::mutate(
    `Team member` = stringr::str_remove(.data$user_username, "(?<=[A-Z])[a-z]+")
  ) |>
  dplyr::select(.data$id, .data$task_id, .data$task_name, .data$description, .data$user_username, .data$`Team member`, .data$start, .data$end, .data$diff_hours) |>
  dplyr::rename(ID = .data$id)

### get spaces ----
spaces <- httr::GET(glue::glue("https://api.clickup.com/api/v2/team/{team_id}/space?archived=false"), httr::add_headers(Authorization = auth_clickup))

spaces_json <- httr::content(spaces, "parsed")

spaces_ds <- dplyr::tibble(result = spaces_json[["spaces"]]) |>
  tidyr::unnest_wider(col = .data[["result"]]) |>
  dplyr::select(.data$id, .data$name) |>
  dplyr::rename(space_name = .data$name)

### get tasks ----
get_tasks <- function(task_id, .delay, .num_cols) {
  task <- httr::GET(
    glue::glue("https://api.clickup.com/api/v2/task/{task_id}/?include_subtasks=true"),
    httr::add_headers(Authorization = auth_clickup)
  )
  task_json <- list(task = list(httr::content(task, "parsed")))

  task_ds <- tryCatch(
    {
      tibble::tibble(result = task_json[["task"]]) |>
        tidyr::unnest_wider(col = .data[["result"]])
    },
    error = function(e) {
      data.frame(
        id = task_id,
        err = err_desc
      )
    }
  )

  ### wrong result has ncol two
  if (ncol(task_ds) == .num_cols) {
    task_ds <- task_ds |> dplyr::mutate(id = task_id)
  }

  ### seconds
  Sys.sleep(.delay)
  task_ds
}

tasks_id <- time_ds$task_id
tasks_id <- unique(tasks_id[!is.na(tasks_id)])

tasks_ds <- purrr::map_df(tasks_id, function(x) get_tasks(x, delay, err_num_cols)) |>
  tidyr::unnest_wider(.data$list, names_sep = "_") |>
  tidyr::unnest_wider(.data$folder, names_sep = "_") |>
  tidyr::unnest_wider(.data$space, names_sep = "_") |>
  dplyr::select(.data$id, .data$list_name, .data$folder_name, .data$space_id, .data$url, contains("err"))

### join spaces and tasks ----
tasks_ds <- tasks_ds |>
  dplyr::left_join(spaces_ds, by = c("space_id" = "id")) |>
  dplyr::select(-.data$space_id)

### join time entries and tasks ----
result <- time_ds |>
  dplyr::left_join(tasks_ds, by = c("task_id" = "id")) |>
  dplyr::relocate(c("list_name", "folder_name", "space_name"), .after = task_name)

### time_entries write to googlesheet ----
sheet_new <- result |>
  dplyr::mutate(Project = team_name) |>
  dplyr::mutate(folder_name = ifelse(.data$folder_name == "hidden", "", .data$folder_name)) |>
  dplyr::mutate(
    dt_load = as.character(lubridate::now(tzone = time_local)),
    start = lubridate::as_datetime(.data$start),
    end = lubridate::as_datetime(.data$end)
  ) |>
  dplyr::rename(
    Space = .data$space_name,
    Folder = .data$folder_name,
    List = .data$list_name,
    Task = .data$task_name,
    Description = .data$description,
    `Link to the task` = .data$url,
    Start = .data$start,
    End = .data$end,
    Hours = .data$diff_hours
  ) |>
  dplyr::select(
    .data$ID,
    .data$Project,
    .data$Space,
    .data$Folder,
    .data$List,
    .data$Task,
    .data$`Team member`,
    .data$Description,
    .data$`Link to the task`,
    .data$Start,
    .data$End,
    .data$Hours,
    dplyr::contains("err"),
    .data$dt_load
  ) |>
  dplyr::arrange(.data$`Team member`, .data$Start) |>
  dplyr::mutate(Description = as.character(.data$Description))

### check colnames err
if (!"err" %in% colnames(sheet_new)) {
  sheet_new <- sheet_new |>
    dplyr::mutate(err = "") |>
    dplyr::relocate(err, .before = .data$dt_load)
}

### auth ----
file_con <- file(name_google)
writeLines(auth_google, file_con)
close(file_con)
googlesheets4::gs4_auth(path = name_google)


### update sheet
to_sheet <- sheet_new |>
  dplyr::arrange(.data$`Team member`, .data$Start)

### check crossing ----
left <- to_sheet |>
  dplyr::select(
    .data$ID,
    .data$Start,
    .data$End,
    .data$`Team member`
  ) |>
  dplyr::mutate(
    start = lubridate::floor_date(.data$Start, "minute"),
    end = lubridate::floor_date(.data$End, "minute")
  )

right <- to_sheet |>
  dplyr::select(
    .data$ID,
    .data$Start,
    .data$End,
    .data$`Team member`,
    .data$dt_load
  ) |>
  dplyr::mutate(
    start = lubridate::floor_date(.data$Start, "minute"),
    end = lubridate::floor_date(.data$End, "minute")
  )

BiocManager::install("IRanges", update = F, ask = F)

crossing_time <- fuzzyjoin::interval_inner_join(left, right, by = c("start", "end")) |>
  dplyr::filter(
    .data$ID.x != .data$ID.y,
    .data$`Team member.x` == .data$`Team member.y`,
    .data$end.x != .data$start.y,
    .data$end.y != .data$start.x
  ) |>
  dplyr::rowwise() |>
  dplyr::mutate(ID = list(sort(c(.data$ID.x, .data$ID.y)))) |>
  dplyr::mutate(ID = paste(.data$ID, collapse = "|")) |>
  dplyr::ungroup() |>
  dplyr::distinct(.data$ID, .keep_all = T) |>
  dplyr::select(-c(
    .data$start.x,
    .data$start.y,
    .data$end.x,
    .data$end.y,
    .data$`Team member.y`,
    .data$ID
  )) |>
  dplyr::rename(`Team member` = .data$`Team member.x`) |>
  dplyr::relocate(.data$`Team member`, .before = .data$ID.x)



## write to table ----
googlesheets4::write_sheet(
  crossing_time,
  link,
  sheet_crossing
)

googlesheets4::write_sheet(
  to_sheet,
  link,
  sheet_tm
)
