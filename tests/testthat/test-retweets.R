test_that("get_retweets returns tweets data", {
  x <- get_retweets("1363488961537130497")
  expect_equal(is.data.frame(x), TRUE)
  expect_named(x)
  expect_true(all(colnames(x) %in% colnames(tweet(NULL))))
})

test_that("get_retweets returns user data", {
  x <- get_retweets("1363488961537130497")
  expect_s3_class(users_data(x), "data.frame")
})

test_that("get_retweeters returns users", {
  x <- get_retweeters("1363488961537130497")
  expect_equal(is.data.frame(x), TRUE)
  expect_named(x)
  expect_true("user_id" %in% names(x))
})
