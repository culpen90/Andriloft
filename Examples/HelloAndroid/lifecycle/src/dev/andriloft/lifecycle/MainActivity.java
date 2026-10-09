package dev.andriloft.lifecycle;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.widget.TextView;

/** Records the real class initialization and Activity lifecycle order. */
public class MainActivity extends Activity {
    static {
        Log.i("Lifecycle", "class-init");
    }

    public MainActivity() {
        super();
        Log.i("Lifecycle", "constructor");
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        Log.i("Lifecycle", "create");
        TextView text = new TextView(this);
        text.setText("Lifecycle callbacks execute from real Android bytecode.");
        setContentView(text);
    }

    @Override
    protected void onStart() {
        super.onStart();
        Log.i("Lifecycle", "start");
    }

    @Override
    protected void onResume() {
        super.onResume();
        Log.i("Lifecycle", "resume");
    }

    @Override
    protected void onPause() {
        super.onPause();
        Log.i("Lifecycle", "pause");
    }

    @Override
    protected void onStop() {
        super.onStop();
        Log.i("Lifecycle", "stop");
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        Log.i("Lifecycle", "destroy");
    }
}
