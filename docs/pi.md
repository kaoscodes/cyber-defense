# Use the endpoint in pi

This guide shows how to add the endpoint to the [pi](https://github.com/earendil-works/pi) coding agent. Do the steps in the [README](../README.md#install) first. After the deployment, the file `.env` contains the endpoint values.

Tested with pi 1.5.0.

## 1. Find the values

You need two values:

- The endpoint ID. This command shows it:

  ```bash
  grep RUNPOD_ENDPOINT_ID .env
  ```

- The full path of this repository. This command shows it:

  ```bash
  pwd
  ```

## 2. Add the provider

Open the file `~/.pi/agent/models.json`. If the file does not exist, create it with this content:

```json
{
  "providers": {
  }
}
```

Add this block in the `providers` object. If the object contains other providers, put a comma between the blocks.

```json
"runpod-cyberorca": {
  "baseUrl": "https://<endpoint-id>.api.runpod.ai/v1",
  "api": "openai-completions",
  "apiKey": "!sed -n 's/^RUNPOD_API_KEY=//p' /path/to/cyber-defense/.env",
  "compat": {
    "supportsDeveloperRole": false,
    "supportsReasoningEffort": true,
    "maxTokensField": "max_tokens",
    "thinkingFormat": "chat-template",
    "chatTemplateKwargs": {
      "enable_thinking": { "$var": "thinking.enabled" },
      "reasoning_effort": { "$var": "thinking.effort", "omitWhenOff": true }
    }
  },
  "models": [
    {
      "id": "cyberorca-vision",
      "name": "CyberOrca 27B Vision (RunPod)",
      "reasoning": true,
      "input": ["text", "image"],
      "contextWindow": 262144,
      "maxTokens": 32768,
      "thinkingLevelMap": {
        "minimal": "low", "low": "low", "medium": "medium",
        "high": "xhigh", "xhigh": "xhigh", "max": "xhigh"
      },
      "cost": { "input": 0.09, "output": 2, "cacheRead": 0, "cacheWrite": 0 }
    }
  ]
}
```

Change two lines:

- In `baseUrl`, replace `<endpoint-id>` with the endpoint ID.
- In `apiKey`, replace `/path/to/cyber-defense` with the path of this repository.

The table shows the function of each setting.

| Setting | Function |
|---|---|
| `apiKey` | The `!` at the start tells pi to run the command. The command reads the key from `.env`. Thus the key is not in the pi configuration. |
| `supportsDeveloperRole: false` | The chat template of the model does not accept the `developer` role. |
| `thinkingFormat` and `chatTemplateKwargs` | pi sends the reasoning settings to the chat template of the model. |
| `thinkingLevelMap` | The model accepts three reasoning levels only: `low`, `medium` and `xhigh`. The map changes each pi level to one of these levels. |
| `input` | The model accepts text and images. |
| `contextWindow` | The context size of the endpoint: 262,144 tokens. |
| `cost` | Approximate cost in USD for 1M tokens. pi uses it only to show the cost of a session. |

## 3. Make sure that pi finds the model

```bash
pi --list-models runpod
```

The output must contain this line:

```
runpod-cyberorca  cyberorca-vision  262.1K   32.8K    yes       yes
```

If the line is not there, the file `models.json` is not valid JSON. Examine the commas and the brackets.

## 4. Start pi

```bash
pi --model runpod-cyberorca/cyberorca-vision
```

To send one question without the interactive mode:

```bash
pi --model runpod-cyberorca/cyberorca-vision -p "Explain SSRF in three sentences."
```

To send an image, put `@` before the file name:

```bash
pi --model runpod-cyberorca/cyberorca-vision @screenshot.png "What does this page show?"
```

In a session that runs, use the `/model` command to change to this model.

## 5. Optional: make it the default model

Open the file `~/.pi/agent/settings.json` and set these values:

```json
"defaultProvider": "runpod-cyberorca",
"defaultModel": "cyberorca-vision",
"defaultThinkingLevel": "medium"
```

Then the command `pi` uses this model. Sessions that are open continue with their current model. Start a new session, or use `/model`.

## Reasoning levels

Set the level with `--thinking`:

```bash
pi --model runpod-cyberorca/cyberorca-vision --thinking low
```

| pi level | Level of the model | Use |
|---|---|---|
| `off` | no reasoning | Short answers |
| `minimal`, `low` | `low` | Fast work |
| `medium` | `medium` | Default |
| `high`, `xhigh`, `max` | `xhigh` | Hard problems. Slow, and it uses many tokens. |

## Problems

| Problem | Cause and solution |
|---|---|
| The first answer comes after 10 s to 40 s. | The endpoint had no worker. RunPod started one. See [Cold start](../README.md#cold-start). The subsequent answers are fast. |
| The first answer after the deployment does not come, or pi shows an error. | RunPod copies the image and the model files to a GPU machine. This can take 10 minutes or more. Send the message again. |
| Error 401. | The key is not correct. Run the command from the `apiKey` line (without the `!`) in a terminal. It must print your RunPod API key. |
| The endpoint rejects a request. | Each worker does one request at a time, and the endpoint has 3 workers maximum. This occurs when more than 3 requests run at the same time. Wait, or increase the number of workers. See [Operations](../README.md#operations). |
