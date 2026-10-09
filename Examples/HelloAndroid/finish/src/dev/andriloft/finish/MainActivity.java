package dev.andriloft.finish;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;

/** Finishes before creating a window so no start/resume callback should run. */
public class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        Log.i("Finish", "create");
        finish();
    }

    @Override
    protected void onStart() {
        super.onStart();
        Log.i("Finish", "start");
    }

    @Override
    protected void onResume() {
        super.onResume();
        Log.i("Finish", "resume");
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        Log.i("Finish", "destroy");
    }
}
