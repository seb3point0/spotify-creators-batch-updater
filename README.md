# Spotify Creators Update Script

A flexible script to update Spotify podcast episode metadata using a CSV file.

## Setup

1. **Copy the example environment file:**
   ```bash
   cp env.example .env
   ```

2. **Get your SHOW_ID:**
   - Login to [Spotify for Creators](https://creators.spotify.com)
   - Navigate to any episode in your podcast
   - Look at the URL in your browser address bar
   - The SHOW_ID is the first long string after `/show/`
   
   Example URL:
   ```
   https://creators.spotify.com/pod/show/<showId>/episode/<episodeId>/details
                                         ^^^^^^^^  This is your SHOW_ID
   ```

3. **Get your COOKIE_STRING:**
   - Stay logged in to [Spotify for Creators](https://creators.spotify.com)
   - Click on any episode to edit it
   - Open Developer Tools (F12 or Right-click → Inspect)
   - Go to the **Network** tab
   - Make any small change to the episode (e.g., add a space to the description)
   - Click **Save**
   - In the Network tab, look for a request named `update?isMumsCompatible=true`
   - Right-click on that request → **Copy** → **Copy as cURL**
   - Paste into a text editor
   - Find the part that says `-b '...'`
   - Copy everything inside the quotes after `-b`
   
   Example:
   ```bash
   curl '...' \
     -b 'sp_t=a7c9d4f2...[VERY LONG STRING]...2847593610294'
        ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
                    This is your COOKIE_STRING
   ```

4. **Configure your `.env` file:**
   - Open the `.env` file you created
   - Replace `your_cookie_string_here` with your actual COOKIE_STRING
   - Replace the SHOW_ID if different
   - Optionally adjust CSV_FILE and LOG_FILE paths
   
   Example `.env`:
   ```bash
   CSV_FILE="spotify.csv"
   LOG_FILE="output.log"
   SHOW_ID="8BHd728..."
   COOKIE_STRING="sp_t=a7c9d4f2...2847593610294"
   ```

## Important Notes

⚠️ **Security & Cookie Expiration:**
- The COOKIE_STRING contains sensitive authentication data - never share it or commit it to version control
- The `.env` file is automatically ignored by git (see `.gitignore`)
- Cookies expire after some time (usually days/weeks) - if the script stops working, get a fresh cookie
- You'll know the cookie expired if you get HTTP 401/403 errors

## CSV Format

The script uses a **semicolon-delimited** CSV format where:
- **First column**: Always `url` (Spotify episode URL)
- **Subsequent columns**: Any valid Spotify API field names
- **Delimiter**: Use semicolon (`;`) to separate values

### Valid API Fields

The following fields are supported (must match exactly):

| Field | Type | Validation | Description |
|-------|------|------------|-------------|
| `title` | string | Cannot be empty | Episode title |
| `description` | string | Cannot be empty | Episode description |
| `publishOn` | string | ISO 8601 format: `YYYY-MM-DDTHH:MM:SS.000Z` | Publish date |
| `episodeNumber` | number | Must be a positive integer | Episode number |
| `seasonNumber` | number or null | Must be a positive integer or `null` | Season number |
| `episodeType` | string | Must be `full`, `trailer`, or `bonus` | Type of episode |
| `isPublished` | boolean | Must be `true` or `false` | Publication status |
| `podcastEpisodeIsExplicit` | boolean | Must be `true` or `false` | Explicit content flag |
| `isDraft` | boolean | Must be `true` or `false` | Draft status |

### Example CSV Files

#### Basic: Update episode numbers only (publishOn auto-fetched)
```csv
url;episodeNumber
https://open.spotify.com/episode/7kR4P9mXz3JwLcYxF2tN8Q;128
https://open.spotify.com/episode/4jKl9M2nRt8P3vF5wX9qYp;42
```
*Note: The script will automatically fetch and use each episode's current `publishOn` date.*

#### Full: Update multiple fields
```csv
url;episodeNumber;title;publishOn
https://open.spotify.com/episode/7kR4P9mXz3JwLcYxF2tN8Q;64;How I became a 10x developer;2015-02-02T00:00:00.000Z
```

#### Custom: Any combination of valid fields
```csv
url;title;description;publishOn
https://open.spotify.com/episode/4jKl9M2nRt8P3vF5wX9qYp;New Title;Updated description;2025-10-02T14:30:00.000Z
```

#### Advanced: Update episode metadata with season and type
```csv
url;episodeNumber;seasonNumber;episodeType;isPublished
https://open.spotify.com/episode/7kR4P9mXz3JwLcYxF2tN8Q;1;1;full;true
https://open.spotify.com/episode/4jKl9M2nRt8P3vF5wX9qYp;2;1;full;true
https://open.spotify.com/episode/3hJk8L1nQt7P2uE4vX8pXm;3;null;bonus;false
```

#### Example: Update explicit flag and draft status
```csv
url;podcastEpisodeIsExplicit;isDraft
https://open.spotify.com/episode/7kR4P9mXz3JwLcYxF2tN8Q;false;false
```

## Usage

1. Create your CSV file with the appropriate headers (first column must be `url`)
   - See `example.csv` for a working example
   - Use semicolons (`;`) to separate values
2. Ensure your `.env` file is configured
3. Run the script:
   ```bash
   ./update_episodes.sh
   ```

## Validation

The script validates all field values before making API calls:

1. ✅ **CSV Format**: Parses semicolon-delimited CSV files with Windows/Unix line endings
2. ✅ **Field Names**: Validates all column headers match valid API fields
3. ✅ **Field Values**: Validates each value according to field type:
   - Numbers must be positive integers
   - Booleans must be `true` or `false`
   - Dates must be in ISO 8601 format: `YYYY-MM-DDTHH:MM:SS.000Z`
   - Episode types must be `full`, `trailer`, or `bonus`
   - Strings cannot be empty
4. ✅ **Episode URLs**: Validates and extracts episode IDs from Spotify URLs
5. ❌ **Stop on Error**: Halts execution if any validation or update fails
