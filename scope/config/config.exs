import Config

# wx_mvu narrates every intent and wx event at debug level — at 30 fps that
# floods the console and scrolls real errors out of scrollback within
# seconds. Keep :info and above.
config :logger, level: :info
