fx_version 'cerulean'
rdr3_warning 'I acknowledge that this is a prerelease build of RedM, and I am aware my resources *will* become incompatible once RedM ships.'
game 'rdr3'
author 'EvolutionInc'
version '1.0.0'
lua54 'yes'

dependencies {
    'oxmysql'
}

shared_scripts {
    'settings.lua',
}

client_script 'client.lua'
server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server.lua'
}

ui_page 'interface/interface.html'

files {
    'interface/interface.html',
    'interface/*',
    'interface/locations/*',
}
