# bearer token doesn't accidentally expose secrets

    Code
      rtweet_app("abc")
    Output
      <Twitter bearer token>

# find auth errors politely

    Code
      find_auth(1:10)
    Error <rlang_error>
      Unrecognised input to `auth`
    Code
      find_auth("not-present")
    Error <rlang_error>
      Can't find saved auth with name 'not-present'

# default_cached_auth() handles 0, 1, and n saved

    Code
      default_cached_auth()
    Error <rlang_error>
      No default authentication found. Please call `auth_setup_default()`

---

    Code
      default_cached_auth()
    Error <rlang_error>
      No default authentication found. Pick existing auth with:
      * auth_as('test1')
      * auth_as('test2')

