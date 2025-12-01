local config = require('tai.config')

if not config.provider then return nil end
return require('tai.' .. config.provider)

