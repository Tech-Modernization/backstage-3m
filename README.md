# [Backstage](https://backstage.io) with [3 Musketeers](https://3musketeers.io)
Spotify Backstage accelerator to generate a 3 Musketeers friendly Backstage application

## Bootstrapping

To generate your own Backstage application, fork this repo and run:

```sh
make bootstrap
```

## Development

To get started running locally, execute the following:
```sh
ENVFILE=env.example make envfile
make deps
make dev
```

You should be able to access the page via: `http://localhost:3000`