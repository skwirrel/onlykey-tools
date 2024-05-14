<?php

# Check cli_set_process_title exists
if (!function_exists('cli_set_process_title')) {
    echo "This script requires a version of PHP with cli_set_process_title() available\n";
    exit;
}

$scriptName = basename(__FILE__);

// set the name of the process to make it easier to kill
echo "Setting process name to $scriptName";
cli_set_process_title($scriptName);
// The above works for ps list, but not for killall so need this as well...
file_put_contents("/proc/".getmypid()."/comm",$scriptName);

# ==================================================================================
# Setup 
# ==================================================================================

$standardScripts = [
    'plain_1page' => '
        type:<<username>>
        key:Tab
        type:<<password>>
        key:Return
    ',
    'plain_2page' => '
        type:<<username>>
        key:Return
        sleep:2
        type:<<password>>
        key:Return
    ',
    'totp_2page' => '
        type:<<username>>
        key:Tab
        type:<<password>>
        key:Return
        sleep:2
        type:<<totp>>
        key:Return
    ',
    'totp_3page' => '
        type:<<username>>
        key:Return
        sleep:2
        type:<<password>>
        key:Return
        sleep:2
        type:<<totp>>
        key:Return
    ',
];

$basePath = getenv('BASE_DIR');

if (empty($basePath)) {
    echo "Error: You must supply the base directory for account storage in the environment variable BASE_DIR e.g.\n";
    echo "    BASE_DIR=/my/password/store/directory/ php -S localhost:<my chosen port> $argv[0]\n";
    exit;
}

$basePath = realpath( $basePath );
if (!is_dir($basePath)) {
    echo "Error: The base directory specified does not exist, or is not readable\n";
}


class Autoloader
{
    public static function register()
    {
        spl_autoload_register(function ($class) {
            if (strpos($class,'\\')===false) return false;
            list( $lib, $class ) = explode('\\',$class,2);
            $file = './'.str_replace('\\', '/', $class).'.php';
            if (file_exists($file)) {
                require $file;
                return true;
            }
            return false;
        });
    }
}
Autoloader::register();

use lfkeitel\phptotp\Totp;
use lfkeitel\phptotp\Base32;

$cacheId=1;

# ==================================================================================
# Functions 
# ==================================================================================

function loadConfig( $userPath ) {
    global $basePath;

    // Prepend the base path to the user-supplied path
    $userPath = $basePath . '/' . $userPath;

    $error = "Couldn't find {$userPath}";

    // Resolve the real, absolute path
    $configFile = realpath($userPath);

    $extensionOptions = ['.txt','.conf'];
    while(!$configFile && count($extensionOptions)) {
        $extension = array_pop($extensionOptions);
        if (preg_match('/\\'.$extension.'$/',$userPath)) continue;
        $testPath = $userPath.$extension;
        $configFile = realpath($testPath);
        if (!$configFile) {
            $error .= " or {$testPath}";
        }
    }

    if (!($configFile && strpos($configFile, $basePath) === 0)) {
        return "$error in {$basePath}";
    }

    if (!file_exists($configFile)) return "Couldn't find config file: $configFile";

    $config = parseData(file_get_contents($configFile),$associative=true);

    // now find the associated password file if not specified in the config
    if (!isset($config['passwordFile'])) {
        $config['passwordFile'] = preg_replace('/\.[^.]+$/', '', $configFile).'.gpg';
        
    }
    if (!file_exists($config['passwordFile'])) return "Couldn't find password file: {$config['passwordFile']}";

    return $config;
}

function saveCache($data, $name) {
    global $cacheId;
    $id=shmop_open($cacheId, "a", 0, 0);
    shmop_delete($id);
    shmop_close($id);
    
    $id=shmop_open($cacheId, "c", 0644, strlen(serialize($data)));
    
    // return int for data size or boolean false for fail
    if ($id) {
        return shmop_write($id, serialize($data), 0);
    }
    else return false;
}

function loadCache($name) {
    global $cacheId;
    $id=shmop_open($cacheId, "a", 0, 0);

    if ($id) $data=unserialize(shmop_read($id, 0, shmop_size($id)));
    else return false;          // failed to load data

    if ($data) {                // array retrieved
        shmop_close($id);
        return $data;
    }
    else return false;          // failed to load data
}

function parseData($lines,$associative=false) {
    // Use preg_replace to remove comment lines or lines that should be ignored, replacing them with an empty string
    $lines = array_filter( preg_replace("/^(#|\/\/).*/m", "", explode("\n",$lines)));

    $return = [];
    $indentMode = false;
    foreach ($lines as $line) {

        if ($indentMode!==false) {
            if (preg_match('/^\s+/',$line)) {
                $indentMode.=trim($line)."\n";
                continue;
            } else {
                $indentMode = false;
            } 
        }

        $line = trim($line);

        unset($value);
        // Split the trimmed line into key and value based on ':'
        list($key, $value) = array_merge(array_map('trim', explode(':', $line, 2)),['']);

        // Might need to support indeted content for other keys in future so use in_array here
        if (in_array($key,['script'])) {
            if (empty($value)) {
                $value = '';
                $indentMode = &$value;
            }
        }

        // Insert into associative array if both key and value are properly set
        if (!empty($key) && isset($value)) {
            if( $associative ) $return[$key] = &$value;
            else $return[] = [$key,&$value];
        }
    }

    return $return;
}

function runScript( $script,&$data ) {
    global $standardScripts;
    if (isset($standardScripts[$script])) {
        $script = $standardScripts[$script];
    } 

    $lines = parseData( $script );

    $lines = array_reverse( $lines );
    $typeDelay=12;

    while ( count($lines) ) {
        $line = array_pop($lines);

        list($command,$params) = $line;

        $params = preg_replace_callback('/<<(\w+)>>/', function ($matches) use ($data) {
            // $matches[1] contains the key found within << >>
            if (isset($data[$matches[1]])) {
                return $data[$matches[1]]; // Return the corresponding value if it exists
            }
            return $matches[0]; // Return the original string if no corresponding key is found
        }, $params);

        $cmd = '';
        $shellParams = escapeshellarg( $params );
        switch (strtolower($command)) {
            case 'typedelay' :
                $typeDelay = (int)$params;
                break;
            case 'type' :
                $cmd = "xdotool type --delay $typeDelay $shellParams";
                break;
            case 'key' :
                $cmd = "xdotool key $shellParams";
                break;
            case 'notify' :
                $cmd = "notify-send -t 10000 $shellParams";
                break;
            case 'sleep' :
                sleep($params);
                break;
                
        }
        if (!empty($cmd)) {
           $output = `$cmd`;
        }
    }
}    

function readPasswordData($passwordFile) {
    if (!file_exists($passwordFile)) return false;
    $passwordFile = escapeshellarg( $passwordFile );
    $contents = `gpg --homedir=~/.gnupg/onlykey -d $passwordFile`;
    $data = parseData($contents,true);
    if (isset($data['totp'])) {
        $key = Base32::decode($data['totp']);
        $data['totp'] = (new Totp())->GenerateToken($key);
    }
    return $data;
}

# ==================================================================================
# Start of main program execution
# ==================================================================================

# Handle calling the script on the command line like this to extract the current secret account data
#    php passwordStore.php <password store base dir> <path to account gpg file>
if (isset($argv[2])) {
    $redirectConfig = loadConfig( $argv[2] );
    print_r($redirectConfig);
    if (!is_array($redirectConfig)) {
        echo "Error: $redirectConfig\n";
        exit;
    }
    echo "Extracting data from {$redirectConfig['passwordFile']}\n";
    echo "Please touch your Onlykey to confirm...\n";
    $data = readPasswordData($redirectConfig['passwordFile']);
    print_r($data);
    exit;
}

$mode = $_GET['mode'] ?? '';

if ($mode=='go') {
    $redirectConfig = loadConfig(loadCache('account'));
    if (!is_array($redirectConfig)) {
        file_put_contents("Error: {$redirectConfig}"); 
        exit;
    }
    $data = readPasswordData($redirectConfig['passwordFile']);
    if (empty($data)) {
        file_put_contents('php://stderr',"Decryption failed for {$redirectConfig['passwordFile']}");
        exit;
    }
    sleep(0.5);
    runScript( $redirectConfig['script'], $data );
    exit;
}

$account = $_GET['account'] ?? '';
$redirectConfig = loadConfig($account);
if (!is_array($redirectConfig)) {
    echo "Error: $redirectConfig\n";
    file_put_contents('php://stderr',"Error: $redirectConfig\n"); 
    exit;
}

if ($mode=='totp') {
    if (empty($account) || $account=='null') $account = loadCache('account');

    $data = readPasswordData($redirectConfig['passwordFile']);
    echo htmlspecialchars($data['totp']);
    ?> 
    <input type="button" id="copyButton" value="Copy" />
    <script>
document.addEventListener('DOMContentLoaded', function() {
    const copyButton = document.getElementById('copyButton');

    copyButton.addEventListener('click', function() {
        // Target specific content for copying
        const contentToCopy = '<?php echo htmlspecialchars($data['totp']);?>';
        navigator.clipboard.writeText(contentToCopy).then(function() {
            // Change button text on successful copy
            copyButton.innerText = 'Copied!';
        }).catch(function(error) {
            // Log error if the copy fails
            console.error('Copy failed', error);
        });
    });
});
    </script>
    <?php
    exit;
}


saveCache($account,'account');
var_dump($redirectConfig);
header('Location: '.$redirectConfig['url']);
exit;
