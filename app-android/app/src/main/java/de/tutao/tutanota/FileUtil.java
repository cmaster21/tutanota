package de.tutao.tutanota;

import android.Manifest;
import android.content.ClipData;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.support.v4.content.FileProvider;
import android.util.Log;
import android.webkit.MimeTypeMap;

import com.ipaulpro.afilechooser.utils.FileUtils;

import org.apache.commons.io.IOUtils;
import org.jdeferred.DoneFilter;
import org.jdeferred.DonePipe;
import org.jdeferred.Promise;
import org.jdeferred.impl.DeferredObject;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLConnection;
import java.util.Iterator;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;

import static android.app.Activity.RESULT_OK;


public class FileUtil {
    private final static String TAG = "FileUtil";
    private static final int HTTP_TIMEOUT = 15 * 1000;

    private final MainActivity activity;

    private final ThreadPoolExecutor networkTasksExecutor = new ThreadPoolExecutor(
            1, // core pool size
            4, // max pool size
            10, // keepalive time
            TimeUnit.SECONDS,
            new LinkedBlockingQueue<>()
    );

    public FileUtil(MainActivity activity) {
        this.activity = activity;
    }


    private Promise<Void, Exception, Void> requestStoragePermission() {
        // Requesting android runtime permissions. (Android 5+)
        // We only need to request the read permission even if we want to get write access. There is only one permission of a permission group necessary to get
        // access to all permission of that permission group. We still have to declare write access in the manifest.
        // https://developer.android.com/guide/topics/security/permissions.html#perm-groups
        return activity.getPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE);
    }

    void delete(final String absolutePath) throws Exception {
        File file = Utils.uriToFile(activity, absolutePath);
        if (absolutePath.startsWith(Uri.fromFile(Utils.getDir(activity)).toString())) {
            // we do not delete files that are not stored in our cache dir
            if (!file.delete()) {
                throw new Exception("could not delete file " + absolutePath);
            }
        }
    }

    Promise<JSONArray, Exception, Void> openFileChooser() {
        final Intent intent = new Intent(Intent.ACTION_GET_CONTENT);
        intent.setType("*/*");
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        intent.putExtra(Intent.EXTRA_LOCAL_ONLY, true);

        final Intent chooser = Intent.createChooser(intent, "Select File");
        return this.requestStoragePermission()
                .then((DonePipe<Void, JSONArray, Exception, Void>) result ->
                        activity.startActivityForResult(chooser)
                                .then(new DonePipe<ActivityResult, JSONArray, Exception, Void>() {
                                    @Override
                                    public Promise<JSONArray, Exception, Void> pipeDone(ActivityResult result) {
                                        JSONArray selectedFiles = new JSONArray();
                                        if (result.resultCode == RESULT_OK) {
                                            ClipData clipData = result.data.getClipData();
                                            try {
                                                if (clipData != null) {
                                                    for (int i = 0; i < clipData.getItemCount(); i++) {
                                                        ClipData.Item item = clipData.getItemAt(i);
                                                        selectedFiles.put(uriToFile(activity.getWebView().getContext(), item.getUri()));
                                                    }
                                                } else {
                                                    Uri uri = result.data.getData();
                                                    selectedFiles.put(uriToFile(activity.getWebView().getContext(), uri));
                                                }
                                            } catch (Exception e) {
                                                return new DeferredObject<JSONArray, Exception, Void>().reject(e);
                                            }
                                        }
                                        return new DeferredObject<JSONArray, Exception, Void>().resolve(selectedFiles);
                                    }
                                }));
    }

    /**
     * @param context
     * @param uri     that starts with content:/ and is not directly accessible as a file
     * @return a resolved file path
     * @throws Exception if the file does not exist
     */
    public static String uriToFile(Context context, Uri uri) throws FileNotFoundException {
        Log.v(TAG, "uri of selected file: " + uri.toString());
        File file = Utils.uriToFile(context, uri.toString());
        if (!file.exists()) {
            throw new FileNotFoundException("Selected file does not exist: " + file.getAbsolutePath());
        } else {
            String fileUri = file.toURI().toString();
            Log.i(TAG, "selected file: " + fileUri);
            return fileUri;
        }
    }

    // @see: https://developer.android.com/reference/android/support/v4/content/FileProvider.html
    Promise<Boolean, Exception, Void> openFile(String fileName, String mimeType) {
        File file = Utils.uriToFile(activity, fileName);

        if (file.exists()) {
            Uri path = Uri.parse(fileName);
            if (path.getAuthority() != null && path.getAuthority().equals("")) {
                path = FileProvider.getUriForFile(activity.getWebView().getContext(),
                        BuildConfig.FILE_PROVIDER_AUTHORITY, file);
            }
            Intent intent = new Intent(Intent.ACTION_VIEW);
            intent.setDataAndType(path, getCorrectedMimeType(fileName, mimeType));
            intent.setFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
            return activity.startActivityForResult(intent)
                    .then((DoneFilter<ActivityResult, Boolean>) result -> result.resultCode == RESULT_OK);
        } else {
            throw new Error("file does not exist");
        }
    }

    private String getCorrectedMimeType(String fileName, String storedMimeType) {
        if (storedMimeType == null || storedMimeType.isEmpty() || storedMimeType.equals("application/octet-stream")) {
            String extension = FileUtils.getExtension(fileName);
            if (extension.length() > 0) {
                String newMimeType = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension.substring(1));
                if (newMimeType != null && !newMimeType.isEmpty()) {
                    return newMimeType;
                } else {
                    return "application/octet-stream";
                }
            } else {
                return "application/octet-stream";
            }
        } else {
            return storedMimeType;
        }
    }


    long getSize(String absolutePath) {
        return Utils.uriToFile(activity.getWebView().getContext(), absolutePath).length();
    }

    String getMimeType(String absolutePath) {
        String mimeType = FileUtils.getMimeType(Utils.uriToFile(activity.getWebView().getContext(), absolutePath));
        if (mimeType == null) {
            mimeType = "application/octet-stream";
        }
        return mimeType;
    }

    String getName(String absolutePath) {
        return Utils.uriToFile(activity.getWebView().getContext(), absolutePath).getName();
    }

    String upload(final String absolutePath, final String targetUrl, final JSONObject headers) throws IOException, JSONException {
        File file = Utils.uriToFile(activity.getWebView().getContext(), absolutePath);
        HttpURLConnection con = (HttpURLConnection) (new URL(targetUrl)).openConnection();
        try {
            con.setConnectTimeout(HTTP_TIMEOUT);
            con.setReadTimeout(HTTP_TIMEOUT);
            con.setRequestMethod("PUT");
            con.setDoInput(true);
            con.setUseCaches(false);
            con.setRequestProperty("Content-Type", "application/octet-stream");
            con.setChunkedStreamingMode(4096); // mitigates OOM for large files (start uploading before the complete file is buffered)
            addHeadersToRequest(con, headers);
            con.connect();

            IOUtils.copy(new FileInputStream(file), con.getOutputStream());

            return con.getResponseCode() + "";
        } finally {
            con.disconnect();
        }
    }

    Promise<String, Exception, Void> download(final String sourceUrl, final String filename, final JSONObject headers) {
        return requestStoragePermission().then((DonePipe<Void, String, Exception, Void>) nothing -> {
            DeferredObject<String, Exception, Void> result = new DeferredObject<>();
            networkTasksExecutor.execute(() -> {
                HttpURLConnection con = null;
                try {
                    con = (HttpURLConnection) (new URL(sourceUrl)).openConnection();
                    con.setConnectTimeout(HTTP_TIMEOUT);
                    con.setReadTimeout(HTTP_TIMEOUT);
                    con.setRequestMethod("GET");
                    con.setDoInput(true);
                    con.setUseCaches(false);
                    addHeadersToRequest(con, headers);
                    con.connect();

                    Context context = activity.getWebView().getContext();
                    File encryptedDir = new File(Utils.getDir(context), Crypto.TEMP_DIR_ENCRYPTED);
                    encryptedDir.mkdirs();
                    File encryptedFile = new File(encryptedDir, filename);

                    IOUtils.copyLarge(con.getInputStream(), new FileOutputStream(encryptedFile),
                            new byte[1024 * 1000]);

                    result.resolve(Utils.fileToUri(encryptedFile));
                } catch (IOException | JSONException e) {
                    result.reject(e);
                } finally {
                    if (con != null) {
                        con.disconnect();
                    }
                }
            });
            return result;
        });
    }

    private static void addHeadersToRequest(URLConnection connection, JSONObject headers) throws JSONException {
        for (Iterator<?> iter = headers.keys(); iter.hasNext(); ) {
            String headerKey = iter.next().toString();
            JSONArray headerValues = headers.optJSONArray(headerKey);
            if (headerValues == null) {
                headerValues = new JSONArray();
                headerValues.put(headers.getString(headerKey));
            }
            connection.setRequestProperty(headerKey, headerValues.getString(0));
            for (int i = 1; i < headerValues.length(); ++i) {
                connection.addRequestProperty(headerKey, headerValues.getString(i));
            }
        }
    }

    void clearFileData() {
        // FIXME delete cached files (currently only implemented for ios)
    }
}
